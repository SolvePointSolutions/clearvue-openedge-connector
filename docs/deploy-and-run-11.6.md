# Deploy & Run on OpenEdge 11.6 / PASOE (POC walking skeleton)

SOL-58 walking skeleton: `/health` and `/product-structure`. This describes how to
compile, deploy, configure, and run the connector on a real OpenEdge **11.6** /
PASOE box against QAD MFG/PRO, and how to prove the two genuinely-open items
(auto-reconnect and latency).

> **No live 11.6/MPI box was available when this was scaffolded.** Everything
> below is the deploy recipe; the steps that *require* the live environment to
> verify are flagged **[LIVE-ONLY]**. No results are faked.

> **Observed runtime (2026-07-02, SOL-119 fault injection):** pensacola.home runs
> **OpenEdge 12.8** ("MSAS Agent Starting Up -- Progress OpenEdge Release 12.8"), not 11.6.
> **Ruling (Rod, 2026-07-02):** no 11.6 environment is available right now — develop and prove
> on 12.8 and assume Progress backwards compatibility, but all connector code stays
> **11.6-language-safe** per CONTRIBUTING; nothing in this repo may assume a 12.x-only
> ABL feature without a version check. Downversion support gets proven on the client's 11.6
> test site when it becomes available; those checks remain **[LIVE-ONLY]** until then.

## 0. Layout

```
src/pasoe/ClearVue/Connector/
  Rest/     GetHealth.p                    # GET /health           (REST-adapter ENTRY SEAM)
            GetProductStructure.p          # GET /product-structure (REST-adapter ENTRY SEAM)
  Config/   ConnectorConfig.cls            # domain, db name, connect params, api key (env-sourced)
  Web/      ConnectorError.cls             # contract Error body + code/category/status mapping
            ErrorClassifier.cls            # SOL-119: connection-state classification table
  Logging/  ConnectorLog.cls               # SOL-119: server-side raw-diagnostic log (CVERR)
  Data/     DatabaseConnection.cls         # EnsureConnected() -- bounded probe + connect (SOL-119)
            SessionActivate.p              # session-activate hook (persistent connection)
  Queries/  ProductStructureQuery.cls      # ported xx-bmpsrp.p BOM explosion (clean re-impl)
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
     `part`/`site`/`correlationId` as QUERY params and the `Authorization` HEADER mapped to the
     `.p`'s `authHeader` input param. **Two distinct names, do not mix them up:** the ABL param is
     `authHeader` (the identifier `authorization` is a reserved ABL keyword on 11.6 and will not
     compile); the header value expression reads the real inbound header, i.e.
     `${http.header['Authorization']}` — **not** `${http.header['authHeader']}`. Mapping the value
     from `authHeader` reads a header that does not exist, hands the `.p` an empty string, and
     `ApiKeyAuthenticator` fails closed → 401. See `config/resourceModel.example.xml`.
   Publish/package the service into a **`.paar`** and deploy it under
   `PASOEContent/WEB-INF/adapters/rest/<service>/` on the instance (`oedeploy` / PDSOE publish).
2. **Session-activate.** Merge `config/pasoe-instance.properties.example` into the instance's
   `conf/openedge.properties` (`srvrActivateProc=ClearVue/Connector/Data/SessionActivate.p`) and
   add the compiled connector root to the ABL app PROPATH.
3. **Do NOT put the ERP DB in the agent startup parameters** (`agentStartupParam` /
   the ABL app's session startup `-db …`). **Observed live (2026-07-02):** with `mfgpro`
   in the agent startup params and the DB down, the **whole MSAS agent failed to boot**
   (status **-1005**, error **5479**) — the connector then can't even serve `/health` or a
   structured 503 while the ERP bounces, defeating the design goal. The connection is owned
   exclusively by `DatabaseConnection` (connect at session-activate via
   `SessionActivate.p`, self-healing per request via `EnsureConnected()` — both handle
   connect-from-scratch). One requirement remains: the runtime `-ld` in the `.pf`
   (`CLEARVUE_DB_LOGICAL_NAME`) must match the logical name the r-code was **compiled**
   against, or schema references fail at r-code load.

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
# -> StructureComponent[] root row (Quantity 1) + children  (samples/product-structure.example.json)

# A part that EXISTS but has no BOM -> 200 with ONLY the root row (NOT 404):
curl -s -H "Authorization: Bearer $CLEARVUE_CONNECTOR_API_KEY" \
  "http://<host>:<port>/<webapp>/clearvue/erp/v1/product-structure?part=HOUSING-100&site=1000"
# -> single root row  (samples/product-structure-no-bom.example.json)

# 401 (no/blank bearer), 400 (missing part), 404 ONLY when the part is absent
# from pt_mstr (genuinely not in the ERP) are the other paths.
```

## 6. [LIVE-ONLY] Prove auto-reconnect (bounded — SOL-119 rework)

> First live run (2026-07-02) proved classification/sanitization end-to-end but took
> **~3 minutes** to 503: the default DB CONNECT makes ~50 OS-level tries (~103s each cycle
> observed, error 1432). The bounded probe+`-ct` design replaces that — re-prove with the
> expected timings below. See `resilience-and-errors.md` §1b.

1. Issue a successful `/product-structure` call (warms the persistent connection).
2. Bounce the MFG/PRO broker mid-session (`proshut` / restart the DB).
3. Immediately re-issue the same call.
   - **DB back up:** `EnsureConnected()` probes (fast), reconnects with ONE `-ct 1`
     CONNECT, returns **200** in ~1–2s (the bounce is invisible).
   - **Broker still down (port closed):** **503 `ERP_UNAVAILABLE`**, `retryable:true`,
     in **~1.5–2s** (probes fail fast). Worst case ~7.5–9s when the host black-holes the
     SYN (full probe timeouts + ceiling). **NOT minutes.**
   - **Broker mid-shutdown (accepts TCP, hangs the DB connect):** probe passes, the single
     `-ct 1` CONNECT fails after one OS try (~2s observed) → **503 `ERP_DISCONNECTED`** —
     bounded in tries, not wall-clock (the documented residual corner).
   - Every 503 body: sanitized `message`/`diagnostic` (no db name / class / OE code) + a
     `correlationId`; grep the agent log for `CLEARVUE-CONNECTOR correlationId=<id>` to get
     the raw detail (host:port, probe counts, OE error).
4. **Pin any additional OE connection-failure error code.** `1432` was observed and is
   live-pinned in the `ErrorClassifier` base table (with `1006`, `1422`, `1423`, `748`,
   `793`). If a different code appears in the agent log, pin it WITHOUT a rebuild via
   `CLEARVUE_CONNECTION_STATE_ERROR_CODES=<code>=ERP_UNAVAILABLE` (or `=ERP_DISCONNECTED`),
   then fold it into the base table. **OBSERVED CODES:** `1432` (2026-07-02, downed broker);
   agent-boot failure with DB in startup params: `5479` / status `-1005` (see §4.3).

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
| `useReturnValue` status mapping | **verified on 11.6** (2026-07-02) — `RETURN "401"` surfaced as a real HTTP 401 during auth bring-up; `RETURN "200"` on a successful lookup | — |
| `type="HEADER"` Authorization mapping | **verified on 11.6** (2026-07-02) — inbound `Authorization` header reaches the `.p` `authHeader` param and authorizes end-to-end | — |
| Auto-reconnect on broker restart | classification/sanitization **live-proven 2026-07-02** but took ~3 min; bounded probe+`-ct` rework (SOL-119) **needs re-proof** | §6 re-run; expect seconds, not minutes |
| Disconnect error-code precision | `1432` **observed live 2026-07-02** (downed broker) + boot-failure `5479`/`-1005`; pinned in `ErrorClassifier` | §6 capture any additional codes |
| Latency vs **real** MPI schema | **not measured** (synthetic = floor only) | §7 |
| Read-only grants confirmed | feasibility TODO | MPI to provision |

### REST-adapter model vs WebHandler — what changed, and the residual risks

The rework preserves the contract via two conveniences that were trivial in `WebHandler` but become
**configuration + 11.6-behavior** dependencies in the classic REST-adapter model. **Both were
confirmed on a live 11.6 box on 2026-07-02** — the fallbacks below are retained for the record but
were not needed:

- **HTTP status from the `.p`** — met via `useReturnValue="true"` + `RETURN "<code>"`. **Confirmed:**
  `RETURN "401"` surfaced as a real HTTP 401 during auth bring-up and `RETURN "200"` on a successful
  lookup, so the adapter maps the return value to the status line on this instance. (Retained
  fallback, unused: if an instance ever surfaces only a fixed 200, keep the status in the body —
  `Error.code` / an explicit `status` field — and have the SaaS read it; that would be a contract
  addition raised as a cross-repo request, NOT a silent change.)
- **Authorization header → param** — met via `type="HEADER"` mapping (`authHeader` ←
  `${http.header['Authorization']}`). **Confirmed:** the inbound `Authorization` header reaches the
  `.p` param and authorizes end-to-end; the classic REST adapter maps the header to a CHARACTER param
  (unlike PASOE Web handlers, which cannot read `Authorization`). (Retained fallback, unused: if an
  instance strips it, an `X-API-Key` header is also mappable — but that diverges from the contract's
  `BearerAuth`, so it too would be a cross-repo contract note, not a unilateral change.)

Everything else (JSON shape/field names, reconnect/503 body, wire formats) is identical to the
WebHandler version — only the entry seam moved from a class to a mapped `.p`.
