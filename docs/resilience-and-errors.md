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

## 2. Error model (contract)

Defined in `openapi/clearvue-erp-connector.v1.yaml` (schema `Error`). Every field exists to
answer "what happened, can we retry, and how do we help the client?"

| Field | Purpose |
|---|---|
| `code` | Stable machine code (enum). |
| `category` | Coarse class for routing handling/support: REQUEST, AUTH, DATA, ERP_CONNECTIVITY, INTERNAL. |
| `retryable` | Whether ClearVue may auto-retry (transient DB conditions). |
| `retryAfterSeconds` | Backoff hint for retryable errors. |
| `correlationId` | Matches SaaS ↔ connector logs for a support case. |
| `timestamp` | When it occurred. |
| `diagnostic` | Safe, operator-facing hint (no secrets/PII/ERP internals). |

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
