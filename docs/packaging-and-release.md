# Packaging & release — the customer builds, we make the build reproducible (SOL-1003)

**Status:** decision locked (Rod, 2026-08-31). Implementation not started — this page records
*what* was decided and *why the obvious alternative is wrong*, so the design is not re-litigated
when someone starts the work.

## Decision

**The versioned deliverable is this implementation, not the contract.** This repository gets
tagged releases and a scripted, reproducible build **that the customer runs on their own box**.

Explicitly **not** per-customer builds produced by SolvePoint. That scales linearly with customers
and puts us inside their release path — we would be shipping a rebuilt artifact every time a
customer's schema changed.

If [SOL-171] (partner connector SDK) later makes the *contract* a separately versioned artifact,
that is additive and does not overturn this.

## Why the ClearVue.ConnectorAgent pattern does not transfer

The .NET agent that talks to this connector already has a full signing and distribution pipeline
(Authenticode via Azure Artifact Signing; a public dist repo carrying checksummed GitHub
Releases). Reaching for it here is the obvious first instinct and **all three legs fail**:

| Their mechanism | Why it does not apply here |
|---|---|
| Authenticode code signing | Authenticode is a **PE format**. R-code is not a PE. There is nothing to sign — this is *inapplicable*, not deferred. Do not file a signing ticket for the ABL side. |
| A public distribution repo | That exists because `ClearVueSaaS` is **private**, so customers could not download anonymously. **This repository is already public** (Apache-2.0). The problem it solves does not exist here. |
| Shipping a prebuilt binary | R-code is compile-bound to the customer's **schema** *and* **logical DB name**. `docs/deploy-and-run-11.6.md` §4: *"`CLEARVUE_DB_LOGICAL_NAME` must match the logical name the r-code was compiled against, or schema references fail at r-code load."* A prebuilt drop is therefore **not portable between customers**. |

The third row is the load-bearing one. It is not a preference — it is what forces the shape of
everything else. We cannot hand over a binary, so the deliverable is source plus a build that runs
the same way every time.

## What exists today

Source only. The repository root holds exactly four files (`.gitignore`, `CONTRIBUTING.md`,
`LICENSE`, `README.md`). **There is no build script, no packaging script, and no release process.**

The deploy guide is honest about this, and its own status table is the specification for what is
missing:

| From `docs/deploy-and-run-11.6.md` | Today |
|---|---|
| §3 Compile | A hand-typed interactive recipe — `COMPILE ClearVue/Connector/Rest/GetProductStructure.p SAVE.` |
| §4 REST service | Must be published into a `.paar` and dropped under `PASOEContent/WEB-INF/adapters/rest/<service>/` |
| §8 *"REST `.paar` build + URI mapping"* | mapping authored (`resourceModel.example.xml`); **not packaged** |
| §8 *"Clean compile vs schema + OE 11.6"* | **not done here** |

## Scope

1. **A non-interactive build.** Compiles `src/pasoe` → r-code deterministically, taking the schema
   connection and DB logical name as parameters. PCT/ANT is the obvious vehicle. **PDSOE-only is
   not acceptable** — it cannot run unattended, which defeats the entire purpose.
2. **`.paar` packaging** for the REST service, driven from `resourceModel.example.xml` rather than
   hand-assembled on the box.
3. **Version stamping from the tag.** ⚠️ **Do this first — it is the smallest item and the one
   that makes the rest mean anything.** `"1.0.0"` is currently a hardcoded literal in **two**
   places, `src/pasoe/ClearVue/Connector/Rest/GetHealth.p:45` and `:55`. So `/health` reports a
   version unrelated to what is deployed, **and the two literals can drift from each other**. A
   versioned-release story is meaningless while the artifact cannot say which version it is.
4. **A tag and release convention**, with a stated relationship to the SaaS-side contract version.
5. **Verification wired into the build**, using what already exists — `test/smoke/route-coversheet-smoke.sh`
   and `tests/ClearVue/Connector/ConnectorUnitTests.cls`.

## Non-goals

Code signing (no PE to sign). A distribution repository (this repo is already public).
Per-customer builds by SolvePoint. Linux/Docker packaging of the ABL side.

## Acceptance

- [ ] A clean checkout builds to r-code + `.paar` via **one documented command**, on a box with
      OE 11.6 and a connected schema, with **no interactive steps**.
- [ ] `/health` returns the **tagged** version, from a single source, on an artifact built that way.
- [ ] `deploy-and-run-11.6.md` §3/§4 are replaced by the scripted path, and §8's two
      "not packaged" / "not done here" rows are retired or restated as genuinely-remaining work.
- [ ] The smoke script passes against an artifact **built by the script**, not one built by hand.

## Related

* [`docs/deploy-and-run-11.6.md`](deploy-and-run-11.6.md) — the manual procedure this replaces
* [`docs/feasibility-11.6.md`](feasibility-11.6.md) — the 11.6 constraint envelope
* [`docs/contract-vocabulary.md`](contract-vocabulary.md) — wire vocabulary, locked
* Ticket **SOL-1003**; related **SOL-171** (partner SDK — where a versioned *contract* would live)
