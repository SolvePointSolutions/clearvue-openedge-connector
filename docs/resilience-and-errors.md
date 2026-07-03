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
- **Bounded PROBE + at most ONE CONNECT** (SOL-119 rework — see §1b for why blind CONNECT
  retries blew the budget by minutes). Up to *N* bounded socket probes of the broker with a
  short backoff, ceiling-checked between attempts (reconnect ceiling **~6s**); a DB-level
  CONNECT (itself `-ct`-bounded) is issued **at most once**, and only after a probe answered.
- **Clean stale state.** If the connection is half-dead, `DISCONNECT` before re-`CONNECT`.
- **Outcome → contract:**
  - reconnect succeeds → normal 200 response (the bounce was invisible).
  - broker never answers a bounded probe → `503 ERP_UNAVAILABLE`, `retryable: true`
    (we *know* the upstream is unreachable — down/mid-restart/blocked).
  - broker answered but the single CONNECT failed (mid-shutdown broker, refused login) →
    `503 ERP_DISCONNECTED`, `retryable: true`, `retryAfterSeconds`, safe `diagnostic`.
  - `504 ERP_TIMEOUT` is **reserved for a genuinely slow-but-alive upstream** (query-duration
    budget); the reconnect path no longer emits it — a down broker is `ERP_UNAVAILABLE`.

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

## 1b. Bounded connect (SOL-119 live-proof rework)

**The live measurement that forced this design:** the ABL database `CONNECT` statement is
**synchronous** and by default makes **~50 OS-level tries** before returning failure. On
pensacola.home (2026-07-02 fault injection) a single CONNECT against the downed `mfgpro`
broker blocked **103 seconds** before failing with OE 1432; three loop attempts produced a
**~3-minute** 503 instead of the ~6s budget. The reconnect ceiling is only checkable
*between* attempts — it cannot preempt a CONNECT in flight.

Two **verified** Progress mechanisms bound the wait (do not invent others):

1. **Socket pre-probe with `-clientConnectTimeout <ms>`** on the ABL Socket `CONNECT()`
   method — supported for non-SSL sockets since **OpenEdge 11.3** (11.6-safe), SSL since
   10.2B07/11.2. Caveat: **on OE 11 two connection attempts are made**, so the effective
   wait can be ~2× the configured value; **OE 12 makes a single attempt**. Source:
   Progress KB 000051142 ("How to specify a socket connect timeout for the CONNECT method").
2. **`-ct <n>` (Connection Retry Attempts) on the DB CONNECT** — supported 10.2B/11.x+.
   Without it the CONNECT makes ~50 tries; the connector appends `-ct 1` (config
   `CLEARVUE_CONNECT_CT`) unless the operator's params/.pf already set `-ct`. Source:
   Progress KB "How to reduce the time for a CONNECT statement to return signaling that a
   database is unavailable".

**Flow (`DatabaseConnection:EnsureConnected()`):** derive the broker host:port from the
configured connect params (inline `-H`/`-S` or inside the referenced `.pf` — reused, not
duplicated); loop up to `CLEARVUE_RECONNECT_MAX_ATTEMPTS` **bounded probes**
(`CLEARVUE_PROBE_TIMEOUT_MS`, default 2000 ms) with backoff, ceiling-checked between
attempts; on the **first successful probe issue exactly ONE `-ct`-bounded CONNECT** — there
is **no retry loop of blind CONNECTs**. Probes never answer → `ERP_UNAVAILABLE`. Probe
answered but CONNECT failed → `ERP_DISCONNECTED`. Endpoint not derivable (e.g.
shared-memory params, no `-H`/`-S`) → skip the probe, single `-ct`-bounded CONNECT.

### Worst-case wall time for the 503 path (defaults: 3 attempts, 2s probe, 750ms backoff, 6s ceiling, `-ct 1`)

| Scenario | Wall time to the 503 | Notes |
|---|---|---|
| Broker port closed (typical stopped DB) | **~1.5–2s** | probes fail fast (TCP refused) → `ERP_UNAVAILABLE` |
| Host unreachable / SYN black-hole | **~7.5s** (OE 12) / **~9s** (OE 11, probe doubling) | probes eat the full timeout; ceiling stops the loop → `ERP_UNAVAILABLE` |
| Broker accepts TCP but hangs the DB connect (mid-`proshut`) | probe (fast) + **one** CONNECT try — **~2s observed live, but NOT hard-bounded** | `-ct 1` caps tries, not wall-clock; this is the honest residual corner. If it recurs chronically, lower the agent-side HttpClient timeout is the backstop (ladder above). |
| DB back up (recovered bounce) | probe (~ms) + CONNECT (~1–2s) → **200** | the bounce is invisible |

> **Honesty note:** the budget is *near*-hard, not hard. Every probe is wall-clock-bounded,
> but the single post-probe CONNECT is bounded in *tries* (`-ct 1`), not in seconds. Progress
> provides no wall-clock timeout for the DB CONNECT statement itself; the agent/gateway
> timeout layers above remain the final backstop for that corner.

> **Observed runtime note (2026-07-02):** pensacola.home runs **OpenEdge 12.8** (MSAS agent
> log). **Ruling (Rod, 2026-07-02):** no 11.6 environment is available right now; develop and
> prove on 12.8, assume Progress backwards compatibility, and keep all connector code
> 11.6-language-safe per CONTRIBUTING (the mechanisms above are supported on both, with the
> OE 11 probe-doubling caveat). Downversion support will be proven on the client's 11.6 test
> site when available — until then 11.6 rows in the status table stay **[LIVE-ONLY]**.

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
   structured bounded-connect path (§1b → `503 ERP_UNAVAILABLE`/`ERP_DISCONNECTED`) instead
   of raising 1006 at r-code load.
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
| 1432 | cannot reach a server (network/firewall) — **live-pinned 2026-07-02** ("Could not connect to server for database …, errno 0") | `ERP_UNAVAILABLE` | ERP_CONNECTIVITY | 503 | true | (same) |
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
