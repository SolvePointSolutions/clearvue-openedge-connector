# Contract vocabulary — ClearVue business language on the wire (SOL-51)

**Status:** locked decision (Rod + Iowa). Recorded here so future connector and
ClearVue SaaS work stays aligned.

## Decision

The connector's REST contract speaks **ClearVue business vocabulary**, not ERP
vocabulary. ERP-specific terms (MFG/PRO `pt_*`/`ps_*` names, "site", "domain") stay
**inside** the connector; the wire is vendor-agnostic and canonical.

For `GET /product-structure` the inbound query params are:

| Wire param (business vocabulary) | Meaning | Was (ERP vocabulary) |
|---|---|---|
| `partNumber` | The part identifier to look up. | `part` |
| `facility`   | The **external facility code the ERP uses to identify the location** — a string code, e.g. `"1000"`. | `site` |
| `correlationId` | Optional caller-supplied correlation id (unchanged). | `correlationId` |

`domain` is **not** on the wire at all. One connector instance serves one ERP
domain; the domain is **connector configuration** (`ConnectorConfig`, sourced from
the environment), never a request parameter.

## The `facility` rule (do not get this wrong)

`facility` carries the **external facility code the ERP uses** — a plain string the
target ERP recognizes for the location. It is **NOT a ClearVue facility Guid**.

- ClearVue SaaS must send the external facility **code**, not the internal facility
  Guid, on this param.
- The connector maps the external facility code to the MFG/PRO **site** internally
  (`GetProductStructure.p`, the `cSite = facility` mapping seam). For QAD MFG/PRO the
  external facility code IS the site value today, so the mapping is a direct
  assignment — but it is kept as an explicit, single-home seam so any future
  facility→site translation (a config-driven map for a customer whose facility codes
  differ from their site codes) has exactly one place to live.
- Because the translation happens inside the connector, the ERP term "site" never
  crosses the wire.

## Scope of this change (and the follow-up)

SOL-51 aligned the **built** endpoint, `/product-structure`, only. The DRAFT,
not-yet-built `/product-route` and `/product-cover-sheet` endpoints still reference
the legacy `part`/`site` parameters in `openapi/clearvue-erp-connector.v1.yaml`.
Aligning those two to `partNumber`/`facility` is a **follow-up** to be done when each
endpoint is implemented, so the whole contract lands on one vocabulary.

## Related cross-repo note (not a connector change)

The connector owns the wire contract; ClearVue SaaS consumes it. When the SaaS
ConnectorAgent builds a `/product-structure` request it must supply the **external
facility code** on `facility` (not the facility Guid) and must not send `part`,
`site`, or `domain`. That is a ClearVue SaaS-side conformance concern (Iowa/Tucker's
lane) — surfaced here as a cross-repo dependency, not implemented in this repo.
