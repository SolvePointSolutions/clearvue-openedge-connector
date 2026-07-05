# Synthetic Test Database — Setup Runbook (SOL-58)

The connector POC needs *a* database to run against. This builds a **minimal,
synthetic** MFG/PRO-shaped test DB on an OpenEdge 11.6 install — just enough for
`/product-structure` to execute and return a **deterministic, diffable** result.

> **This is not QAD's schema.** The fixtures define only the table/field *names*
> the connector queries (names are facts) plus the minimum fields + indexes the
> query opens. No QAD `mfgprod.df` dictionary, formats, labels, help, or
> validation is reproduced. The fixtures (`.st` / `.df` / `.d`) live under
> `test/fixtures/` and are **gitignored** — they are never committed. Only this
> runbook and the expected-output sample are committed.

## Fixtures (local, gitignored — `test/fixtures/`)

| File | What it is |
|---|---|
| `clearvue-test.st`  | minimal Type II storage-area structure |
| `clearvue-test.df`  | SolvePoint's own minimal defs: `pt_mstr`, `ptp_det`, `ps_mstr`, `bom_mstr` |
| `pt_mstr.d`         | 3 parts (PUMP-ASSY-100, HOUSING-100, IMPELLER-50) |
| `ptp_det.d`         | part-by-site rows (no BOM-code override) |
| `ps_mstr.d`         | the multi-level BOM component lines |
| `bom_mstr.d`        | empty (no non-inventory parents in this fixture) |

> The `/product-structure` buffer set in the `.df` == the buffers
> `ProductStructureQuery` opens (`pt_mstr`, `ptp_det`, `ps_mstr`, `bom_mstr`).
> The routing + cover-sheet tables (`ro_det`, `wc_mstr`, `cmt_det`, `cp_mstr`,
> `cm_mstr`, `ad_mstr`) and two extra `ptp_det` fields are added in
> [§ Routing + cover-sheet fixtures](#routing--cover-sheet-fixtures-product-route--product-cover-sheet)
> below — apply those before smoke-testing the two new endpoints offline.

## Build the DB (OpenEdge 11.6)

```sh
cd test/fixtures

# 1. create an empty multi-volume DB from the storage structure
prostrct create clearvue-test clearvue-test.st

# 2. copy the empty schema into it
procopy $DLC/emptyn clearvue-test          # empty DB matching -cpinternal

# 3. load the synthetic schema definitions (.df)
#    (batch, no GUI): load .df via the data dictionary load
pro clearvue-test -1 -p prodict/load_df.p -param "clearvue-test.df"
#    -- or interactively: Data Administration > Admin > Load Data and Definitions
#       > Data Definitions (.df)

# 4. load the seed data (.d) -- one per table
pro clearvue-test -1 -p prodict/load_d.p   # interactive bulk loader
#    -- or load each table's .d from Data Administration > Load Table Contents (.d)
#       loading pt_mstr.d, ptp_det.d, ps_mstr.d, bom_mstr.d
```

## Serve it / connect as `qaddb`

The connector references the **logical** name `qaddb` (`CONNECTED("qaddb")`), so
the test DB must be connected with `-ld qaddb` even though its physical name is
`clearvue-test`:

```sh
# start a server (client/server, like prod)
proserve clearvue-test -S 50000 -H localhost

# the connector's .pf for the test DB (copy qaddb.pf.example, keep -ld qaddb):
#   -db clearvue-test  -ld qaddb  -S 50000  -H localhost  -RO
# point CLEARVUE_DB_CONNECT_PARAMS at it; set CLEARVUE_ERP_DOMAIN=MPI
```

A single-user smoke check without PASOE (run the entry .p directly, which calls
the same OOABL logic the REST adapter would):

```sh
pro -db clearvue-test -ld qaddb -1 -p ClearVue/Connector/Rest/GetProductStructure.p
# (set CLEARVUE_ERP_DOMAIN=MPI and CLEARVUE_CONNECTOR_API_KEY first; pass
#  partNumber=PUMP-ASSY-100 facility=1000 and "Bearer <key>" as the authorization param.)
```

## Expected output (deterministic — diff targets)

Three deterministic cases prove the SOL-58 root-row / 404 semantics:

### Case 1 — part with a multi-level BOM (200, root + children)

`GET /product-structure?partNumber=PUMP-ASSY-100&facility=1000` must return exactly
[`samples/product-structure.example.json`](../samples/product-structure.example.json):

- Root row `PUMP-ASSY-100` (Level `Parent`, **Qty 1** — root convention).
- `HOUSING-100` and `IMPELLER-50` at Level `1` (first explosion level).
- `GASKET-KIT` at Level `.2` (under IMPELLER-50), `Description` "Item not in
  inventory" and `UnitOfMeasure` **null** (intentionally absent from `pt_mstr`,
  proving the not-in-inventory branch).

### Case 2 — part that EXISTS but has no BOM (200, root row ONLY)

`GET /product-structure?partNumber=HOUSING-100&facility=1000` must return exactly
[`samples/product-structure-no-bom.example.json`](../samples/product-structure-no-bom.example.json):
a single root row for `HOUSING-100` (Level `Parent`, Qty 1). `HOUSING-100` is in
`pt_mstr` but is no parent in `ps_mstr`, so it exists with no components — this is
**200 with just the root row, NOT a 404**.

### Case 3 — part that does NOT exist (404)

`GET /product-structure?partNumber=NOPE-999&facility=1000` must return **404** with the
contract `Error` body (`code: NOT_FOUND`). `NOPE-999` is absent from `pt_mstr`, so
the existence gate yields 0 rows → 404. This is the ONLY 404 path.

> **Existence gate:** 404-vs-200-empty is decided by a real `pt_mstr` lookup, not
> by "did the explosion return rows" — so a real purchased/raw part (Case 2) is
> never falsely reported as not-found.

> **Level label note (faithful to the ported legacy logic):** the first
> explosion level is labelled `1`, the second `.2`, the third `..3`, etc.
> (`BuildLevelLabel`). This is the legacy `xx-bmpsrp.p` indentation convention,
> re-implemented; it is intentional, not an off-by-one.

Diff the live responses against the committed samples to confirm no regression:

```sh
curl -s -H "Authorization: Bearer $CLEARVUE_CONNECTOR_API_KEY" \
  "http://<host>:<port>/<webapp>/clearvue/erp/v1/product-structure?partNumber=PUMP-ASSY-100&facility=1000" \
  | diff - ../../samples/product-structure.example.json          # Case 1 (from test/fixtures)

curl -s -H "Authorization: Bearer $CLEARVUE_CONNECTOR_API_KEY" \
  "http://<host>:<port>/<webapp>/clearvue/erp/v1/product-structure?partNumber=HOUSING-100&facility=1000" \
  | diff - ../../samples/product-structure-no-bom.example.json   # Case 2
```

## Routing + cover-sheet fixtures (`/product-route` + `/product-cover-sheet`)

`ProductRouteQuery` and `ProductCoverSheetQuery` open buffers the base
`clearvue-test.df` doesn't define yet. Append the schema below to
`clearvue-test.df` (or load it as a second `.df`), then load the seed `.d`
rows. The seed makes the two committed samples
([`product-route.example.json`](../samples/product-route.example.json),
[`product-cover-sheet.example.json`](../samples/product-cover-sheet.example.json))
deterministic diff targets for `PUMP-ASSY-100` / facility `1000`.

> Still SolvePoint's own minimal defs — only the names + the exact fields/indexes
> the two queries open. Gitignored like the rest of `test/fixtures/`.

### Schema additions (append to `clearvue-test.df`)

```
# --- two new fields on the existing ptp_det (routing code + pallet multiple) ---
ADD FIELD "ptp_routing" OF "ptp_det" AS character
  ORDER 50
ADD FIELD "ptp_ord_mult" OF "ptp_det" AS decimal
  DECIMALS 0
  ORDER 60

ADD TABLE "ro_det"
  AREA "TestData"
  DUMP-NAME "ro_det"
ADD FIELD "ro_domain"    OF "ro_det" AS character ORDER 10
ADD FIELD "ro_routing"   OF "ro_det" AS character ORDER 20
ADD FIELD "ro_op"        OF "ro_det" AS integer   ORDER 30
ADD FIELD "ro_std_op"    OF "ro_det" AS character ORDER 40
ADD FIELD "ro_desc"      OF "ro_det" AS character ORDER 50
ADD FIELD "ro_wkctr"     OF "ro_det" AS character ORDER 60
ADD FIELD "ro_mch"       OF "ro_det" AS character ORDER 70
ADD FIELD "ro_start"     OF "ro_det" AS date      ORDER 80
ADD FIELD "ro_end"       OF "ro_det" AS date      ORDER 90
ADD FIELD "ro_setup"     OF "ro_det" AS decimal DECIMALS 3 ORDER 100
ADD FIELD "ro_run"       OF "ro_det" AS decimal DECIMALS 9 ORDER 110
ADD FIELD "ro_wait"      OF "ro_det" AS decimal DECIMALS 3 ORDER 120
ADD FIELD "ro_move"      OF "ro_det" AS decimal DECIMALS 3 ORDER 130
ADD FIELD "ro_yield_pct" OF "ro_det" AS decimal DECIMALS 2 ORDER 140
ADD FIELD "ro_tool"      OF "ro_det" AS character ORDER 150
ADD FIELD "ro_fsm_type"  OF "ro_det" AS character ORDER 160
ADD FIELD "ro_cmtindx"   OF "ro_det" AS decimal DECIMALS 0 ORDER 170
ADD INDEX "ro_routing" ON "ro_det"
  AREA "TestIndex"
  PRIMARY
  INDEX-FIELD "ro_domain" ASCENDING
  INDEX-FIELD "ro_routing" ASCENDING
  INDEX-FIELD "ro_op" ASCENDING

ADD TABLE "wc_mstr"
  AREA "TestData"
  DUMP-NAME "wc_mstr"
ADD FIELD "wc_domain" OF "wc_mstr" AS character ORDER 10
ADD FIELD "wc_wkctr"  OF "wc_mstr" AS character ORDER 20
ADD FIELD "wc_mch"    OF "wc_mstr" AS character ORDER 30
ADD FIELD "wc_desc"   OF "wc_mstr" AS character ORDER 40
ADD INDEX "wc_wkctr" ON "wc_mstr"
  AREA "TestIndex"
  UNIQUE PRIMARY
  INDEX-FIELD "wc_domain" ASCENDING
  INDEX-FIELD "wc_wkctr" ASCENDING
  INDEX-FIELD "wc_mch" ASCENDING

ADD TABLE "cmt_det"
  AREA "TestData"
  DUMP-NAME "cmt_det"
ADD FIELD "cmt_domain" OF "cmt_det" AS character ORDER 10
ADD FIELD "cmt_indx"   OF "cmt_det" AS decimal DECIMALS 0 ORDER 20
ADD FIELD "cmt_cmmt"   OF "cmt_det" AS character EXTENT 15 ORDER 30
ADD INDEX "cmt_indx" ON "cmt_det"
  AREA "TestIndex"
  UNIQUE PRIMARY
  INDEX-FIELD "cmt_domain" ASCENDING
  INDEX-FIELD "cmt_indx" ASCENDING

ADD TABLE "cp_mstr"
  AREA "TestData"
  DUMP-NAME "cp_mstr"
ADD FIELD "cp_domain"    OF "cp_mstr" AS character ORDER 10
ADD FIELD "cp_part"      OF "cp_mstr" AS character ORDER 20
ADD FIELD "cp_cust"      OF "cp_mstr" AS character ORDER 30
ADD FIELD "cp_cust_part" OF "cp_mstr" AS character ORDER 40
ADD INDEX "cp_part" ON "cp_mstr"
  AREA "TestIndex"
  PRIMARY
  INDEX-FIELD "cp_domain" ASCENDING
  INDEX-FIELD "cp_part" ASCENDING

ADD TABLE "cm_mstr"
  AREA "TestData"
  DUMP-NAME "cm_mstr"
ADD FIELD "cm_domain" OF "cm_mstr" AS character ORDER 10
ADD FIELD "cm_addr"   OF "cm_mstr" AS character ORDER 20
ADD INDEX "cm_addr" ON "cm_mstr"
  AREA "TestIndex"
  UNIQUE PRIMARY
  INDEX-FIELD "cm_domain" ASCENDING
  INDEX-FIELD "cm_addr" ASCENDING

ADD TABLE "ad_mstr"
  AREA "TestData"
  DUMP-NAME "ad_mstr"
ADD FIELD "ad_domain" OF "ad_mstr" AS character ORDER 10
ADD FIELD "ad_addr"   OF "ad_mstr" AS character ORDER 20
ADD FIELD "ad_name"   OF "ad_mstr" AS character ORDER 30
ADD INDEX "ad_addr" ON "ad_mstr"
  AREA "TestIndex"
  UNIQUE PRIMARY
  INDEX-FIELD "ad_domain" ASCENDING
  INDEX-FIELD "ad_addr" ASCENDING
```

### Seed data (`.d` files, one per table)

`ptp_det.d` — **replace** the base file so `PUMP-ASSY-100` carries a routing
code + pallet multiple (field order: domain, part, site, bom_code, routing,
ord_mult):

```
"MPI" "PUMP-ASSY-100" "1000" "" "PUMP-ASSY-100" 48
"MPI" "IMPELLER-50" "1000" "" "" 0
```

`ro_det.d` (domain, routing, op, std_op, desc, wkctr, mch, start, end, setup,
run, wait, move, yield_pct, tool, fsm_type, cmtindx):

```
"MPI" "PUMP-ASSY-100" 10 "MACHINE" "Rough Machining" "MC01" "M1" ? ? 1.5 0.25 0.1 0.05 98 "T-100" " " 100
"MPI" "PUMP-ASSY-100" 20 "ASSEMBLE" "Final Assembly" "AS01" "A1" ? ? 0.5 0.1 0 0 100 "" " " 0
```

`wc_mstr.d` (domain, wkctr, mch, desc):

```
"MPI" "MC01" "M1" "Machining Cell 1"
"MPI" "AS01" "A1" "Assembly Line 1"
```

`cmt_det.d` (domain, indx, cmmt[1..15]) — two lines populated, rest blank:

```
"MPI" 100 "Deburr all edges" "Inspect per QA-17" "" "" "" "" "" "" "" "" "" "" "" "" ""
```

`cp_mstr.d` (domain, part, cust, cust_part):

```
"MPI" "PUMP-ASSY-100" "ACME01" "ACME-PUMP-X"
```

`cm_mstr.d` (domain, addr) — first 7 chars must match `cp_cust`:

```
"MPI" "ACME01"
```

`ad_mstr.d` (domain, addr, name):

```
"MPI" "ACME01" "Acme Manufacturing Co"
```

> `HOUSING-100` deliberately gets **no** `ptp_det`/`ro_det` row, so it is the
> "part exists, no routing → 200 with an empty array" case.

### Expected results

| Case | Request | Result |
|---|---|---|
| Route — has routing | `GET /product-route?partNumber=PUMP-ASSY-100&facility=1000` | 200, diff-equals [`product-route.example.json`](../samples/product-route.example.json) (2 ops, standalone shape — **no** PiecesPerHour/WorkCenterDescription) |
| Route — no routing | `GET /product-route?partNumber=HOUSING-100&facility=1000` | 200, `[]` (part exists, no `ro_det`) |
| Route — not found | `GET /product-route?partNumber=NOPE-999&facility=1000` | 404, `code: NOT_FOUND` |
| Route — no bearer | (same, no Authorization header) | 401, `code: UNAUTHORIZED` |
| Route — missing param | `GET /product-route?facility=1000` | 400, `code: BAD_REQUEST` |
| Cover sheet | `GET /product-cover-sheet?partNumber=PUMP-ASSY-100&facility=1000` | 200, diff-equals [`product-cover-sheet.example.json`](../samples/product-cover-sheet.example.json) (header + reused structure + full-shape route + 2 comments) |
| Cover sheet — not found | `GET /product-cover-sheet?partNumber=NOPE-999&facility=1000` | 404 |
| **SOL-119 DB down** | any lookup with the DB/broker stopped | **503**, `code: ERP_UNAVAILABLE`\|`ERP_DISCONNECTED`, `retryable: true`, `category: ERP_CONNECTIVITY`, `correlationId` present, **no** db/class/OE-number leakage (raw detail in the agent log under subsystem `CVERR`, keyed by correlationId); returns within the ~6s budget; recovers with no PASOE bounce after restart |

Drive all of these with [`test/smoke/route-coversheet-smoke.sh`](../test/smoke/route-coversheet-smoke.sh)
(run it from Rod's dev box, not loopback-on-server).

> **Note (embedded route depth):** the cover sheet's `Structure` is the FULL
> canonical BOM explosion (it reuses `ProductStructureQuery`), NOT the legacy
> cover sheet's shallow MPI-specific 2-level walk — one BOM truth shared with
> `/product-structure`. The cover sheet's `Route` is the full RouteStep shape
> (adds `PiecesPerHour` = 1/run, `WorkCenterDescription` from `wc_mstr`) plus the
> harvested `Comments`.

## Latency caveat (important)

A timing taken against THIS synthetic DB is a **smoke-test floor, not a real
measurement** — three parts in one storage area on local disk are not remotely
representative of MPI's production v10 schema, data volume, indexes, or network.
Treat any number from the synthetic DB only as "the code path runs"; the real
latency figure (resilience-and-errors.md budget: connector ≤7s) must be measured
against the production MFG/PRO schema. See `deploy-and-run-11.6.md` §7.
