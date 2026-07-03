# Resilience & Error Model

Two related requirements, driven by a known field reality: **the MFG/PRO database is
restarted often, which severs the connector's client/server connection.**

1. The connector must **auto-reconnect** so most DB bounces never reach ClearVue as an error.
2. When a drop *can't* be healed in time, the connector returns a **structured error** rich
   enough for ClearVue to react and for support to assist the client.

---

## 1. Auto-reconnect (connector behavior)

**Goal:** a routine DB restart should be invisible — the connector detects the dropped
client/server connection, re-establishes it, and serves the request, all within the time
budget. An error is returned only when reconnection genuinely fails.

**Behavior (design intent):**

- **Pre-flight check.** Before running a query, verify the logical DB is connected
  (`CONNECTED("qaddb")`). If not, reconnect before querying.
- **Mid-query drop.** If a query fails due to a connection-failure condition, treat it as a
  disconnect: reconnect and re-run the query **once**.
- **Bounded retry + backoff.** Attempt reconnect up to *N* times with a short backoff,
  staying inside the connector's total response budget (**≤7s**; reconnect ceiling **~6s**) —
  see the timeout ladder below. Do **not** spin indefinitely.
- **Clean stale state.** If the connection is half-dead, `DISCONNECT` before re-`CONNECT`.
- **Outcome → contract:**
  - reconnect succeeds → normal 200 response (the bounce was invisible).
  - reconnect fails within budget → `503 ERP_DISCONNECTED`, `retryable: true`,
    `retryAfterSeconds`, with a safe `diagnostic`.
  - host/broker unreachable at all → `503 ERP_UNAVAILABLE`, `retryable: true`.
  - reconnect ate the whole budget → `504 ERP_TIMEOUT`, `retryable: true`.

### Timeout ladder (must hold, with margin)

Each layer must be strictly larger than the one it wraps, so the **inner** layer always wins
the race and its structured error propagates outward. If the layers are equal (today the
connector reconnect ceiling ≈ the agent timeout), a generic timeout masks the retryable
disconnect and ClearVue never learns it can retry.

| Layer | Budget | Notes |
|---|---|---|
| Connector reconnect ceiling | ~6s | bounded retry/backoff |
| Connector total response | ≤7s | query + reconnect |
| Agent HttpClient timeout | 9s | **MUST be set explicitly** — today `MfgProRestQueryExecutor.BuildHttpClient` never sets `client.Timeout`, so it defaults to **100s** and the gateway's 10s fires first, discarding the connector's structured 503/504. Fixing this is prerequisite to the whole error model working. |
| Gateway timeout | 12s | must exceed agent timeout + SignalR round-trip |
| Gateway auto-retry (if enabled) | **1 attempt max**; honor `retryAfterSeconds` clamped ≤5s; single overall wall-clock deadline ~18s across both attempts |

All values configuration-driven so the field can tune without a rebuild. Invariant:
**connector budget < agent timeout < gateway timeout**, each with ~2s margin.

**OpenEdge 11.6 implementation notes (confirm on the spike — see `feasibility-11.6.md`):**

- ABL primitives: `CONNECTED(ldbname)`, `CONNECT VALUE(params)` / `CONNECT -pf …`,
  `DISCONNECT`, error trapping via `NO-ERROR` + `ERROR-STATUS` or `CATCH`.
- Confirm the exact OE connection-failure error code(s) raised on a broker restart so the
  "is this a disconnect?" test is precise (don't reconnect-loop on unrelated errors).
- Confirm the PASOE session connection model: connect at **session-activate** (persistent per
  agent, health-checked per request) vs **per-request** connect. Persistent + health-check is
  preferred for latency; per-request is simpler but slower. Decide on the spike.
- Keep reconnect logic in one place (a shared `EnsureConnected` helper) so every controller
  inherits it.

**SaaS side (ClearVue):** honor `retryable` — a single bounded auto-retry on
`ERP_DISCONNECTED`/`ERP_TIMEOUT` makes a DB restart invisible to the user. Surface
`category` + `correlationId` in logs/UI for support. (Tracked: SaaS error-model alignment.)

---

## 1a. Connection-state classification (SOL-119)

A DB-down fault does not always arrive through `EnsureConnected()`. Because the query
classes' r-code references the ERP schema, a stopped DB can surface as a **raw
Progress error** — e.g. OE **1006** "Database `<name>` not connected." raised while
loading/instantiating a class that references `pt_mstr` — *before* the pre-flight gate
runs. Untreated, that raw fault fell into the generic catch-all and went on the wire as
`INTERNAL` / 500 / `retryable:false` with the raw message (db name, class name, OE error
number) leaked in `diagnostic`.

Two defenses (both in place):

1. **Pre-flight ordering.** The REST entry seam calls `DatabaseConnection:EnsureConnected()`
   **before** instantiating any schema-referencing query class, so a stopped DB takes the
   structured reconnect path (`503 ERP_DISCONNECTED`) instead of raising 1006 at r-code load.
2. **Classification before the catch-all.** `ClearVue.Connector.Web.ErrorClassifier` is the
   single, table-driven "is this a known transient upstream state?" test. Every seam's
   generic `CATCH` classifies first; only a genuinely unknown fault falls through to the
   non-retryable fallback (`ERP_QUERY_ERROR` at the query seam, `INTERNAL` at the `.p` seam).

### The classification table (single source: `ErrorClassifier`)

| OE error | Condition | `code` | `category` | HTTP | `retryable` | Sanitized wire reason |
|---|---|---|---|---|---|---|
| 1006 | Database not connected (r-code referencing a disconnected DB) | `ERP_DISCONNECTED` | ERP_CONNECTIVITY | 503 | true | "upstream ERP connection is temporarily unavailable; retry shortly" |
| 1422 | client/server connection-loss family | `ERP_DISCONNECTED` | ERP_CONNECTIVITY | 503 | true | (same) |
| 793 | lost connection to server | `ERP_DISCONNECTED` | ERP_CONNECTIVITY | 503 | true | (same) |
| 1423 | no server for database (broker down/restarting) | `ERP_UNAVAILABLE` | ERP_CONNECTIVITY | 503 | true | "upstream ERP is temporarily unavailable; retry shortly" |
| 748 | server/system out of resources (connect refused) | `ERP_UNAVAILABLE` | ERP_CONNECTIVITY | 503 | true | (same) |
| 1432 | cannot reach a server (network/firewall) | `ERP_UNAVAILABLE` | ERP_CONNECTIVITY | 503 | true | (same) |
| *anything else* | unknown fault | `INTERNAL` (`ERP_QUERY_ERROR` at the query seam) | INTERNAL | 500 (502) | false | "unexpected connector fault; quote the correlationId to support" |

The classifier walks **all** messages on the raw error (wrapped errors bury the number
past message 1); first table hit wins. Sites extend the table without a rebuild via
`CLEARVUE_CONNECTION_STATE_ERROR_CODES` (comma-separated `oeErrNum=CONTRACT_CODE` pairs) —
use it to pin the code observed on a given site's broker restart or DB login failure,
then fold it into the base table. Note a **login failure** during (re)connect already
maps to `ERP_DISCONNECTED`/503 by construction: any in-budget `CONNECT` failure inside
`EnsureConnected()` takes that path.

### Diagnostic sanitization + correlationId (SOL-119)

- **Wire `message`/`diagnostic` are stable, sanitized reasons.** No logical/physical db
  name, no fully-qualified class name, no Progress error number ever crosses the wire —
  those are infrastructure topology.
- **The raw detail survives server-side.** Every `ConnectorError` carries a
  `RawDetail` property that is **never serialized**; the entry seam logs it via
  `ClearVue.Connector.Logging.ConnectorLog` to the PASOE agent log (subsystem `CVERR`),
  line shape: `CLEARVUE-CONNECTOR correlationId=<id> code=<CODE> detail=<raw>`.
- **`correlationId` always exists.** Caller-supplied wins; otherwise the connector
  generates a GUID. It is echoed in every Error body, so support resolves a client
  envelope to the full raw diagnostic by grepping the agent log for the id.

---

## 2. Error model (contract)

Defined in `openapi/clearvue-erp-connector.v1.yaml` (schema `Error`). Every field exists to
answer "what happened, can we retry, and how do we help the client?"

| Field | Purpose |
|---|---|
| `code` | Stable machine code (enum). |
| `category` | Coarse class for routing handling/support: REQUEST, AUTH, DATA, ERP_CONNECTIVITY, INTERNAL. |
| `retryable` | Whether ClearVue may auto-retry (transient DB conditions). |
| `retryAfterSeconds` | Backoff hint for retryable errors. |
| `correlationId` | Matches SaaS ↔ connector logs for a support case. Caller-supplied, or **generated by the connector** when absent — always present on an Error body (SOL-119). |
| `timestamp` | When it occurred. |
| `diagnostic` | Safe, operator-facing hint (no secrets/PII/ERP internals — no db name, class name, or OE error number). The raw detail lives only in the connector log, keyed by `correlationId` (SOL-119). |

### Code → meaning → assistance to the client

| `code` | category | retryable | Means | How to assist the client |
|---|---|---|---|---|
| `ERP_DISCONNECTED` | ERP_CONNECTIVITY | yes | DB connection dropped (usually a DB restart); reconnect failed within budget. | Auto-retries. If persistent, confirm the MFG/PRO DB broker is back up on its host/port. |
| `ERP_UNAVAILABLE` | ERP_CONNECTIVITY | yes | Can't reach the DB host/broker at all. | Check the broker/host/port and network path from the connector host. |
| `ERP_TIMEOUT` | ERP_CONNECTIVITY | yes | Query (or reconnect) exceeded the budget. | Retry; if chronic, review ERP/DB performance for these lookups. |
| `UNAUTHORIZED` | AUTH | no | Missing/invalid connector token. | Fix the connector's configured API token. |
| `NOT_FOUND` | DATA | no | No record for that part/site. | Verify the part/site exists in MFG/PRO for that domain. |
| `BAD_REQUEST` | REQUEST | no | Missing/invalid parameter. | Caller-side bug; check the request. |
| `ERP_QUERY_ERROR` / `INTERNAL` | INTERNAL | no | Unexpected connector/query failure. | Capture `correlationId`; escalate to SolvePoint with it. |

The `diagnostic` + `correlationId` are the support hooks: a client-facing operator can read
the diagnostic, and SolvePoint can pull both connector and SaaS logs by the correlation id.
