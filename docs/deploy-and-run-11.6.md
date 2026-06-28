# Deploy & Run on OpenEdge 11.6 / PASOE (POC walking skeleton)

SOL-58 walking skeleton: `/health` and `/product-structure`. This describes how to
compile, deploy, configure, and run the connector on a real OpenEdge **11.6** /
PASOE box against QAD MFG/PRO, and how to prove the two genuinely-open items
(auto-reconnect and latency).

> **No live 11.6/MPI box was available when this was scaffolded.** Everything
> below is the deploy recipe; the steps that *require* the live environment to
> verify are flagged **[LIVE-ONLY]**. No results are faked.

## 0. Layout

```
src/pasoe/ClearVue/Connector/
  Rest/     GetHealth.p                    # GET /health           (REST-adapter ENTRY SEAM)
            GetProductStructure.p          # GET /product-structure (REST-adapter ENTRY SEAM)
  Config/   ConnectorConfig.cls            # domain, db name, connect params, api key (env-sourced)
  Web/      ConnectorError.cls             # contract Error body + code/category/status mapping
  Data/     DatabaseConnection.cls         # EnsureConnected() -- persistent connect + reconnect
            SessionActivate.p              # session-activate hook (persistent connection)
  Query/    ProductStructureQuery.cls      # ported xx-bmpsrp.p BOM explosion (clean re-impl)
  Security/ ApiKeyAuthenticator.cls        # Authorization: Bearer enforcement (header value)
  Json/     JsonFormat.cls                 # invariant decimals, ISO dates, empty->null
            ProductStructureJsonComposer.cls # hand-composed StructureComponent[] -> LONGCHAR
  config/   resourceModel.example.xml          # REST resource URI->.p->param mapping (template)
            pasoe-instance.properties.example  # session-activate hook + PROPATH (template)
            qaddb.pf.example                    # client/server .pf (template; live = .pf.local, gitignored)
            connector.env.example               # runtime env vars (template)
```

Namespace mirrors the directory: `ClearVue.Connector.*`. Directory = package.

> **Binding model (11.6):** the REST resource URI cannot bind to a class on 11.6, so each
> endpoint's entry point is a **classic REST-adapter `.p`** under `Rest/` (annotated
> `@openapi.openedge.export FILE(type="REST" …)`). The `.p` is a thin seam: it maps the request
> params + Authorization header, calls the unchanged OOABL logic classes, hand-composes the JSON,
> and sets the HTTP status via `useReturnValue="true"` + `RETURN "<code>"`. See
> `docs/feasibility-11.6.md` (Binding-Model Correction).

## 1. Prerequisites

- OpenEdge **11.6** (the OE *platform* serving `mfgprod` must be 11.6 — confirm no
  cross-version client/server mismatch; feasibility §2 TODO).
- A PAS for OpenEdge instance (`pasman create` / OE Explorer).
- A **read-only** MFG/PRO DB account (least privilege; the connector never writes).
- Network path from the connector host to the DB broker host/port.

## 2. Configure (no secrets in source)

1. Copy `config/qaddb.pf.example` → `/etc/clearvue/qaddb.pf.local`, fill in the real
   `-S` / `-H` and the read-only account. (`*.pf.local` is gitignored.)
2. Copy `config/connector.env.example` into the PASOE service environment and set:
   - `CLEARVUE_ERP_DOMAIN` (e.g. `MPI`)
   - `CLEARVUE_DB_LOGICAL_NAME` (`qaddb`)
   - `CLEARVUE_DB_CONNECT_PARAMS=-pf /etc/clearvue/qaddb.pf.local`
   - `CLEARVUE_CONNECTOR_API_KEY` from your secret store (fail-closed if unset)

## 3. Compile

Compile the `.cls`/`.p` under `src/pasoe` to `.r` (PCT/ANT, `COMPILE`, or PDSOE
project). Ensure the OpenEdge JSON + Web assemblies are on PROPATH (standard on
11.6). Example interactive compile from `src/pasoe`:

```
PROPATH = ".,$DLC/tty,$DLC/gui".  /* + OpenEdge JSON/Net assemblies are in $DLC */
COMPILE ClearVue/Connector/Rest/GetProductStructure.p SAVE.
COMPILE ClearVue/Connector/Rest/GetHealth.p SAVE.
/* the OOABL classes the .p's reference compile transitively */
```

> **[LIVE-ONLY] compile verification.** The connector references the DB schema
> (pt_mstr/ps_mstr/ptp_det/bom_mstr) and the OpenEdge JSON/Net classes, so a
> *clean* compile must be done against a connected schema + the OE 11.6 install. It
> could not be compiled here (no 11.6 / MFG-PRO schema). Compile on the box before
> deploy.

## 4. Build the REST service + wire up session-activate

The entry points are mapped `.p`'s, not handler classes:

1. **Map the resource model.** In a PDSOE OpenEdge REST project, define the resources/operations
   per `config/resourceModel.example.xml` (or generate the `.pidl`s from the annotated `.p`'s and
   wire them in the REST editor):
   - `GET /health` → `ClearVue/Connector/Rest/GetHealth.p`
   - `GET /product-structure` → `ClearVue/Connector/Rest/GetProductStructure.p`, with
     `part`/`site`/`correlationId` as QUERY params and `Authorization` as a HEADER param mapped to
     the `authorization` input.
   Publish/package the service into a **`.paar`** and deploy it under
   `PASOEContent/WEB-INF/adapters/rest/<service>/` on the instance (`oedeploy` / PDSOE publish).
2. **Session-activate.** Merge `config/pasoe-instance.properties.example` into the instance's
   `conf/openedge.properties` (`srvrActivateProc=ClearVue/Connector/Data/SessionActivate.p`) and
   add the compiled connector root to the ABL app PROPATH.

Restart the instance. Base URL follows the contract:
`http://<host>:<port>/<webapp>/clearvue/erp/v1`.

## 5. Smoke test

```
# health (no auth per contract)
curl -s http://<host>:<port>/<webapp>/clearvue/erp/v1/health
# -> {"service":"clearvue-openedge-connector","version":"1.0.0","erpReachable":true}

# product-structure (bearer required)
curl -s -H "Authorization: Bearer $CLEARVUE_CONNECTOR_API_KEY" \
  "http://<host>:<port>/<webapp>/clearvue/erp/v1/product-structure?part=PUMP-ASSY-100&site=1000"
# -> StructureComponent[]  (see samples/product-structure.example.json)

# 401 (no/blank bearer), 400 (missing part), 404 (unknown part) are the other paths.
```

## 6. [LIVE-ONLY] Prove auto-reconnect

1. Issue a successful `/product-structure` call (warms the persistent connection).
2. Bounce the MFG/PRO broker mid-session (`proshut` / restart the DB).
3. Immediately re-issue the same call.
   - **Expected:** `EnsureConnected()` sees `CONNECTED("qaddb")=false`, reconnects
     within budget, and returns **200** (the bounce is invisible).
   - If the broker stays down past the reconnect ceiling (~6s): **503**
     `ERP_DISCONNECTED`, `retryable:true`.
4. **Pin the exact OE connection-failure error code.** While the broker is down,
   capture `ERROR-STATUS:GET-NUMBER(1)` from the failed `CONNECT` (the agent log /
   a temporary trace). The documented family is `1423` (no server for database),
   `1422`/`748`/`793` (connection loss). **Add the observed code to
   `DatabaseConnection:IsDisconnectError()`** so mid-query retry triggers only on a
   real disconnect. **RECORD THE OBSERVED CODE HERE:** `__TBD on spike__`.

## 7. [LIVE-ONLY] Measure latency

Time `/product-structure` against the real MPI schema, warm connection, for a few
representative parts (shallow + deep multi-level BOM):

```
curl -s -o /dev/null -w "%{time_total}\n" \
  -H "Authorization: Bearer $CLEARVUE_CONNECTOR_API_KEY" \
  "http://<host>:<port>/<webapp>/clearvue/erp/v1/product-structure?part=<deep-bom>&site=<site>"
```

Budget (resilience-and-errors.md): connector total ≤ **7s**, target **5–7s** worst
case, with the cover sheet as the heavier follow-on. **RECORD MEASURED TIMES HERE:**
`__TBD on spike__` (note part depth + row count per sample).

> **Minimal-synthetic-DB caveat.** A timing against the synthetic test DB
> (`docs/test-db-setup.md`) is a **smoke-test floor only — NOT a production
> measurement.** Three rows in one local storage area do not represent MPI's v10
> schema, data volume, indexes, or network. The real latency figure must come
> from the production MFG/PRO schema; the synthetic number proves only that the
> code path executes within a sane bound.

A no-MFG/PRO option to run the skeleton end-to-end today: build the synthetic
test DB per `docs/test-db-setup.md`, connect it as `-ld qaddb`, and diff the
`/product-structure?part=PUMP-ASSY-100&site=1000` response against
`samples/product-structure.example.json`.

## 8. What still needs the live box

| Item | Status | Needs |
|---|---|---|
| Clean compile vs schema + OE 11.6 | not done here | compile on the box (or the synthetic DB, docs/test-db-setup.md) |
| End-to-end run vs a DB | runnable on the synthetic DB | build fixtures + diff expected JSON |
| REST `.paar` build + URI mapping | mapping authored (`resourceModel.example.xml`); **not packaged** | build/publish the REST service on the box (§4) |
| `useReturnValue` status mapping | designed; **unverified on 11.6** | confirm RETURN "<code>" sets the real HTTP status on this instance |
| `type="HEADER"` Authorization mapping | designed; **unverified on 11.6** | confirm the inbound Authorization header reaches the `.p` param |
| Auto-reconnect on broker restart | code in place; **unverified** | §6 + pin error code |
| Disconnect error-code precision | documented family; **not observed** | §6 capture |
| Latency vs **real** MPI schema | **not measured** (synthetic = floor only) | §7 |
| Read-only grants confirmed | feasibility TODO | MPI to provision |

### REST-adapter model vs WebHandler — what changed, and the residual risks

The rework preserves the contract, but two conveniences that were trivial in `WebHandler` become
**configuration + 11.6-behavior** dependencies in the classic REST-adapter model — both must be
confirmed on the box:

- **HTTP status from the `.p`** — met via `useReturnValue="true"` + `RETURN "<code>"`. This is the
  biggest risk. If, on this exact 11.6 instance, the adapter does **not** map the return value to
  the status line (some configurations only surface a fixed 200 unless the WRITE handler is used),
  the fallback is to keep the status in the body (`Error.code` / an explicit `status` field) and
  have the SaaS read it — a contract addition, raised as a cross-repo request, NOT a silent change.
  Confirm first; the `RETURN "<code>"` path is expected to work.
- **Authorization header → param** — met via `type="HEADER"` mapping. Confirmed by Progress docs
  that the **classic** REST adapter can map a request header to a CHARACTER param (unlike PASOE Web
  handlers, which cannot read `Authorization`). If a given instance still strips it, the fallback is
  an `X-API-Key` header (also mappable) — but that diverges from the contract's `BearerAuth`, so it
  too would be a cross-repo contract note, not a unilateral change.

Everything else (JSON shape/field names, reconnect/503 body, wire formats) is identical to the
WebHandler version — only the entry seam moved from a class to a mapped `.p`.
