# OpenEdge 11.6 / PASOE Feasibility Envelope

**Purpose:** bound the contract design to what an OpenEdge **11.6** connector can actually
produce. Fill this in *before* finalizing `openapi/clearvue-erp-connector.v1.yaml` — every
shape in the contract must be checked off as "producible on 11.6 within budget." This exists
so the 11.6 constraint is an active design input, not an afterthought.

> Status: **core design decisions captured (2026-06-28, Rod).** The four PASOE/ABL calls are
> made (see §1–§4). Remaining is a short list of measure-on-the-spike items: cover-sheet
> latency, the exact OE connection-failure error code on broker restart, and MPI's read-only
> grants / OE-11.6-platform confirmation.

> ### ⚠ BINDING-MODEL CORRECTION (2026-06-28, Rod — authoritative for the target env)
>
> **Conflict found.** This doc originally LOCKED the REST handler style as an
> `OpenEdge.Web.WebHandler` subclass (§1, and the error-semantics resolution in §0 Q2). That
> conflicts with the live 11.6 target: *"In version 11.6 you can't hook up classes directly to
> a REST resource URI. You have to put the class in a .p and map input/output variables or
> datasets."*
>
> **Resolution — binding model changed: `WebHandler` → CLASSIC OpenEdge REST adapter (.p).**
> The REST resource URI maps to an **annotated `.p`** (`@openapi.openedge.export FILE(type="REST"
> …)`) whose INPUT/OUTPUT params are mapped to query-string params, request headers, and a
> LONGCHAR body (see `config/resourceModel.example.xml`, packaged into a `.paar`). This is the
> same transport the legacy adaptor used (`resourceModel.xml` → `.pidl` controllers).
>
> **What does NOT change:** the OOABL logic classes (`ProductStructureQuery`,
> `DatabaseConnection.EnsureConnected()`, `ApiKeyAuthenticator`, `JsonFormat`,
> `ProductStructureJsonComposer`, `ConnectorError`) are unchanged — the `.p` is a thin seam that
> calls them. JSON is still **hand-composed** via the JSON Object Model (not `WRITE-JSON` of a
> dataset). The contract shapes/field names are unchanged.
>
> **How the three WebHandler conveniences are met in the .p model:**
> - **HTTP status codes** — `useReturnValue="true"` maps the procedure's `RETURN "<code>"`
>   (CHARACTER) to the HTTP status line, so real 200/400/401/404/502/503/504 are set from the
>   `.p`. (The legacy used `useReturnValue="false"` and crammed status into a body param — fixed.)
> - **`Authorization: Bearer` header** — surfaced to the `.p` as a CHARACTER input param via a
>   `type="HEADER"` mapping (the classic REST adapter CAN read request headers; PASOE Web
>   handlers cannot read `Authorization`). `ApiKeyAuthenticator:IsAuthorizedHeader()` validates it.
> - **503 `ERP_DISCONNECTED` body** — `ConnectorError:ToJsonString()` → LONGCHAR OUTPUT param,
>   `RETURN "503"`. Maps cleanly.
>
> See `docs/deploy-and-run-11.6.md` for the revised deploy steps. §1/§0 below are annotated to
> reflect this correction.

## 0. Already answered (from Squirrel's lane + the as-built adaptor — don't re-spike)

Squirrel's Progress-REST work (`ClearVueSaaS/docs/modules/Integrations/progress-rest-live-lookup-design.md` §5/§8, the committed `Part + CoverSheet` implementation `c24ca69`) plus our read of the source-of-truth adaptor (`Interact/ClearVueAdaptor/AppServer`) already settle most cover-sheet questions:

- **Endpoint catalog** — `/status`, `/getproductstructure`, `/getproductroute`, `/getproductcoversheet` (per `resourceModel.xml`).
- **Params + auth (as-built)** — `product` / `site` / `apikey` query params (structure spells it `apiKey`); domain hardcoded "MPI". *(The clean contract changes these — canonical `part`/`site`, bearer header, domain = config.)*
- **Cover-sheet fields, joins, envelope** — header (`pt_mstr` + `ps_mstr` + `cs_mstr`) + structure (`ptp_det`) + route (`ro_det` + `wc_mstr`) + comments, with exact `SERIALIZE-NAME`s — from `xx-rprdcvr.p` / `CoverSheetTT.i` / `GetProductCoverSheet.p`.
- **Two route shapes** — standalone route omits `PiecesPerHour`/`WorkCenterDescription`; cover-sheet route includes them.
- **Serialization is possible on 11.6** — the adaptor serializes `dsCoverSheet` via `WRITE-JSON`, so 11.6 *can* produce the envelope — but it used manual `REPLACE`/`TRIM` string-munging to reshape the wrapper.

### Spike questions — mostly resolved by the §1–§4 decisions

1. **Clean serialization** — ✅ **RESOLVED by design.** Build the envelope with the ABL **JSON Object Model** (`JsonObject`/`JsonArray`), hand-composed — not `WRITE-JSON` of a dataset. Full control over nesting/names/types/nulls, so the contract envelope (incl. `Comments` as a plain string array) is produced exactly, with no wrapper and no `REPLACE`/`TRIM` munging. The spike just confirms it on 11.6 (the JSON Object Model is standard there).
2. **Error semantics** — ✅ **RESOLVED (revised binding).** ~~The `OpenEdge.Web.WebHandler` sets the status code directly~~ → on the 11.6 target the **classic REST adapter `.p`** sets the real HTTP status via `useReturnValue="true"` + `RETURN "<code>"` and returns the structured `Error` body as a LONGCHAR OUTPUT param — no legacy `httpResponse`-string ambiguity. So `404`/`503`/`504` are real status lines the SaaS reads (the SOL-55/SOL-56 path). See the Binding-Model Correction above.
3. **Latency / payload** — ⏳ **OPEN (measurement).** Worst-case cover-sheet response time/size against MPI's v10 schema — confirm on the spike (progress-rest §8 Q7).
4. **Auto-reconnect** — ◑ **Design resolved, one fact to confirm.** Persistent per-session connection + per-request `CONNECTED()` health-check/reconnect (one `EnsureConnected` helper). Open: the exact OE connection-failure error code(s) on broker restart, so reconnect triggers only on real disconnects. See `resilience-and-errors.md`.

**Net:** the cover-sheet bellwether is de-risked at the design level. Only the latency measurement and the reconnect error code remain to prove on the spike — neither can reshape the contract; they just tune budgets and the reconnect trigger.

---

## 1. Runtime target

- OpenEdge **11.6** (hard requirement; MPI is on a v10-era MFG/PRO *application* but the OE
  *platform* is 11.6).
- App server: **PASOE** (PAS for OpenEdge) with the REST/Web transport.
- REST handler style: ~~**`OpenEdge.Web.WebHandler` subclass** (DECIDED)~~ **SUPERSEDED — see the
  Binding-Model Correction at the top.** On 11.6 a class cannot bind to a REST resource URI, so
  the entry seam is a **classic OpenEdge REST adapter `.p`** (annotated `@openapi.openedge.export
  FILE(type="REST" …)`) with mapped INPUT/OUTPUT params; status via `useReturnValue="true"` +
  `RETURN "<code>"`, auth header via a `type="HEADER"` param, body via a LONGCHAR OUTPUT param.
  (Still not the DataObject service / WebSpeed; still hand-composed JSON.)

## 2. Database connectivity

- **Client/server** to the MFG/PRO DB via a Progress parameter file (`.pf`), per the legacy
  `mfgproProd.pf` (`-db mfgprod -ld qaddb -S <port> -H <host>`).
- **Read-only** DB account (least privilege). _TODO: confirm the read-only role/grants MPI
  will provision._
- _TODO: confirm the OE platform serving `mfgprod` is 11.6 (no cross-version client/server
  mismatch)._
- **Auto-reconnect** (the DB is restarted often): **persistent per-session connection**
  (connect at session-activate) + per-request `CONNECTED("qaddb")` health-check and reconnect,
  centralized in one `EnsureConnected` helper (DECIDED). _TODO: confirm the exact OE
  connection-failure error code(s) on broker restart so reconnect triggers only on real
  disconnects (not unrelated errors)._ See `resilience-and-errors.md`.

## 3. JSON serialization — DECIDED: JSON Object Model

Build the response JSON with the ABL **JSON Object Model** (`JsonObject` / `JsonArray`),
hand-composed in the handler — **not** `WRITE-JSON` of a ProDataset. This gives exact control
over the nested cover-sheet envelope (header object + structure/route arrays + comments), so:

- The contract envelope is produced **exactly** — no dataset wrapper to fight, no
  `REPLACE`/`TRIM` munging. ✅ (kills the legacy fragility)
- `Comments` as a plain **array of strings** is trivial (a `JsonArray` of strings, not
  `[{comment}]`). ✅
- Canonical field names are set explicitly as each member is added. ✅
- Wire-format standard (DECIDED): **dates → ISO 8601 strings** (e.g. `2026-01-15`); **decimals
  → JSON numbers**, invariant `.` separator, no thousands separators, at the contract's
  per-field scale (Quantity 4dp; Setup/Wait/Move 3dp; Runtime 9dp; YieldPercent 2dp). Format OE
  `DATE`→ISO explicitly; ensure invariant numeric output (watch `-numsep`/`-numdec` so a
  localized session doesn't emit `1,5`). Empty notes → JSON `null`. _Confirm the exact wire
  bytes on the spike._

> The query logic (the MFG/PRO joins) is still ported from `xx-rprdcvr.p` / `xx-rorp.p`; only
> the *serialization* changes — pull rows into temp-tables/buffers as today, then compose the
> JSON by hand instead of `WRITE-JSON` + munge.

## 4. Auth — DECIDED: API key in a header, validated in the entry seam

Read the API key from a request header and compare to a configured secret; reject with
`401 UNAUTHORIZED` on mismatch. (Not `oeablSecurity` — simpler, and matches the contract's
enforced-header model.) **Revised binding:** the header is surfaced to the mapped `.p` as a
CHARACTER input param via a `type="HEADER"` mapping (`config/resourceModel.example.xml`), then
validated by `ApiKeyAuthenticator:IsAuthorizedHeader()`. The classic REST adapter CAN map a
request header to a param — important, because PASOE Web handlers cannot read `Authorization`.

- Header name: **`Authorization: Bearer <key>`** (aligns with the contract's `BearerAuth`). DECIDED.
- _TODO: where the secret lives on the connector host (config / OS secret store) — never in
  source, never sent to the SaaS._ (Implemented: `CLEARVUE_CONNECTOR_API_KEY` via `ConnectorConfig`,
  fail-closed if unset.)

## 5. Performance envelope

- Budget: the SaaS gateway times out at ~10s; the agent allows ~8s. Connector responses
  should target **5–7s** worst case.
- Heaviest query = cover sheet (multi-table join: `pt_mstr`, `ptp_det`, `ps_mstr`, `ro_det`,
  `wc_mstr`, `cs_mstr`). _TODO: confirm typical/worst-case latency against MPI's v10 schema._

## 6. Things to avoid in the contract (11.6 limits)

- No streaming / chunked responses — single synchronous JSON body only.
- No pagination assumed (single-record lookups; structures/routes are small).
- Keep payloads modest; avoid designs that require huge result sets.
- _TODO: add any other 11.6/PASOE limitations Rod knows of._

## 7. Per-operation feasibility checklist

| Operation | Producible on 11.6? | Notes |
|---|---|---|
| `/health` | ✅ | REST-adapter `.p` (`GetHealth.p`); lightweight `CONNECTED()` probe; always 200. |
| `/product-structure` | ✅ | REST-adapter `.p` (`GetProductStructure.p`); flat `JsonArray`; legacy `xx-bmpsrp.p` query logic. |
| `/product-route` | ✅ | REST-adapter `.p`; flat `JsonArray`; legacy `xx-rorp.p` query logic. |
| `/product-cover-sheet` | ✅ design-cleared; latency TBM | Nested envelope hand-composed via JSON Object Model; a *compose* step once the pieces are proven. |

**POC order (walking skeleton):** `/health` (step 0 — proves PASOE deploy + DB connection + auth) → **`/product-structure`** (the real POC: first query, flat `JsonArray`, formatting, **reconnect**, **latency** — exercises every cross-cutting concern) → `/product-route` → `/product-cover-sheet` (compose the nested envelope from the now-proven structure/route pieces + header + comments). The cover sheet no longer needs to go first: its only unique risk — nested serialization — was retired by the JSON Object Model decision (§3), so build the thinnest slice first and let the envelope be an incremental compose. The structure POC must explicitly prove the two genuinely-open items: DB-restart reconnect and cover-sheet-scale latency.

## 8. Open questions for the contract — resolved

- Does the nested cover-sheet serialize natively, or do we flatten? → **Resolved:** hand-build
  with the JSON Object Model; the envelope stays exactly as the contract specifies (no flatten).
- Final auth mechanism? → **Resolved:** API key in the `Authorization: Bearer` header, mapped to
  the REST-adapter `.p` as a `type="HEADER"` param and validated by `ApiKeyAuthenticator`.
- Any field 11.6 can't cleanly produce? → **None expected** — the JSON Object Model gives full
  control; only date/decimal *formatting* to settle on the spike (not a shape change).

**Bottom line for the contract:** no envelope reshaping needed. `clearvue-erp-connector.v1.yaml`
stands as the build target. The spike proves it on real 11.6/MPI and measures latency.
