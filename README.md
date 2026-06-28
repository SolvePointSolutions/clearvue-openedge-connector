# ClearVue OpenEdge Connector

An open-source, on-premises **Progress OpenEdge** connector that serves live, read-only
ERP data to [ClearVue SaaS](https://www.solvepointsolutions.com) over a small, versioned
REST contract. The first supported ERP is **QAD MFG/PRO**.

> **Status: early / work in progress.** The clean target contract is being designed;
> the OpenEdge 11.6 / PASOE implementation follows. Not yet production-ready.

## What it does

ClearVue requests a single record — a product structure (BOM), a routing, or a combined
cover sheet for a part — and this connector executes the lookup locally against the ERP
database and returns canonical JSON. It is **read-only**: it never writes back to the ERP,
and ClearVue never stores the returned data (it is fetched live).

The connector runs inside the customer's network and reaches ClearVue **outbound only** —
no inbound firewall rule, no VPN required.

## The contract is the product

The REST contract in [`openapi/`](openapi/) is the source of truth and a public API. Any
connector (this one, or a future one for another ERP) that implements it can serve ClearVue.
Field names in the contract are canonical; this connector emits them directly.

## Design constraints

- **OpenEdge 11.6** runtime is a hard target (PASOE + the REST/Web handlers). Do not design
  anything into the contract that an 11.6 client cannot produce — see
  [`docs/feasibility-11.6.md`](docs/feasibility-11.6.md).
- **Read-only**, synchronous, single-record lookups. No write-back.
- Connects to the ERP database **client/server** via a Progress parameter file.
- **Resilient to DB restarts.** The ERP DB is restarted often; the connector auto-reconnects
  on client/server drops and returns a structured, retryable error only when it can't —
  see [`docs/resilience-and-errors.md`](docs/resilience-and-errors.md).

## Repository layout

```
openapi/   The versioned REST contract (source of truth)
src/pasoe/ The OpenEdge 11.6 / PASOE web application
           ClearVue/Connector/{Web,Data,Query,Security,Config,Json}/  (ABL OO, ClearVue.Connector.*)
           config/  PASOE handler-route + .pf + env templates (*.example only)
tests/     ABLUnit tests for the connector's pure (non-DB) logic
docs/      Design notes: 11.6 feasibility envelope, resilience/errors, deploy-and-run
samples/   Example responses (*.example.json only; no customer data committed)
```

The walking-skeleton POC (SOL-58) implements `/health` and `/product-structure`.
See [docs/deploy-and-run-11.6.md](docs/deploy-and-run-11.6.md) to compile, deploy,
and run it on a real OpenEdge 11.6 / PASOE box, and to prove the two open items
(auto-reconnect on a DB restart and end-to-end latency).

## A note on QAD intellectual property

This repository contains **SolvePoint's own** query and service code. It does **not** ship
QAD's MFG/PRO data dictionary (`*.df`) or any QAD schema source — those are QAD's property
and are excluded from the repo (see `.gitignore`). Table and field *names* referenced in
queries are facts and are fine.

## License

[Apache License 2.0](LICENSE). See [CONTRIBUTING.md](CONTRIBUTING.md) to contribute.
