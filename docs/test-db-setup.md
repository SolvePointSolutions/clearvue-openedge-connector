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

> The exact buffer set in the `.df` == the buffers `ProductStructureQuery` opens
> (`pt_mstr`, `ptp_det`, `ps_mstr`, `bom_mstr`). `ro_det` / `wc_mstr` / `cs_mstr`
> are routing + cover-sheet tables added when `/product-route` and
> `/product-cover-sheet` are built.

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

A single-user smoke check without PASOE:

```sh
pro -db clearvue-test -ld qaddb -1
# then run the query class against part PUMP-ASSY-100, site 1000, domain MPI
```

## Expected output (deterministic — diff target)

`GET /product-structure?part=PUMP-ASSY-100&site=1000` against this fixture must
return exactly [`samples/product-structure.example.json`](../samples/product-structure.example.json):

- Parent row `PUMP-ASSY-100` (Level `Parent`, Qty 0).
- `HOUSING-100` and `IMPELLER-50` at Level `1` (first explosion level).
- `GASKET-KIT` at Level `.2` (under IMPELLER-50), `Description` "Item not in
  inventory" and `UnitOfMeasure` **null** (intentionally absent from `pt_mstr`,
  proving the not-in-inventory branch).

> **Level label note (faithful to the ported legacy logic):** the first
> explosion level is labelled `1`, the second `.2`, the third `..3`, etc.
> (`BuildLevelLabel`). This is the legacy `xx-bmpsrp.p` indentation convention,
> re-implemented; it is intentional, not an off-by-one.

Diff the live response against the committed sample to confirm no regression:

```sh
curl -s -H "Authorization: Bearer $CLEARVUE_CONNECTOR_API_KEY" \
  "http://<host>:<port>/<webapp>/clearvue/erp/v1/product-structure?part=PUMP-ASSY-100&site=1000" \
  | diff - ../../samples/product-structure.example.json   # path from test/fixtures
```

## Latency caveat (important)

A timing taken against THIS synthetic DB is a **smoke-test floor, not a real
measurement** — three parts in one storage area on local disk are not remotely
representative of MPI's production v10 schema, data volume, indexes, or network.
Treat any number from the synthetic DB only as "the code path runs"; the real
latency figure (resilience-and-errors.md budget: connector ≤7s) must be measured
against the production MFG/PRO schema. See `deploy-and-run-11.6.md` §7.
