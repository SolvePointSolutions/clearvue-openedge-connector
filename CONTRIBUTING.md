# Contributing

Thanks for your interest in the ClearVue OpenEdge Connector.

## Ground rules

- **The contract is the source of truth.** Any change to request/response shape, field
  names, paths, or status codes is a change to [`openapi/`](openapi/) first, reviewed as a
  potential breaking-API change, and then reflected in the implementation. Don't let the code
  and the contract drift.
- **Target OpenEdge 11.6 — ABL language level 11.6.** This connector must compile and run on an
  **OpenEdge 11.6** runtime (PASOE + the classic REST adapter). Treat **11.6 as the ABL language
  baseline**: do not use any ABL syntax, class, method, overload, or property feature introduced
  after 11.6 without raising it first — see [`docs/feasibility-11.6.md`](docs/feasibility-11.6.md)
  (ABL Language Baseline section). Known post-11.6 / fragile-on-11.6 constructs to AVOID:
  - **Inline method-on-method-return chaining** — `obj:MethodA():MethodB()`. Assign the
    intermediate object to a typed variable first. *(Chaining a handle attribute such as
    `hBuf:BUFFER-FIELD("x"):BUFFER-VALUE` is a different, long-supported idiom and is fine.)*
  - **Bare Unknown value `?` as a class constructor/method argument** — e.g.
    `NEW ConnectorError(…, ?)` or `oAuth:IsAuthorizedHeader(?)`. On 11.6 the compiler cannot
    infer a datatype for a bare `?` in a call-argument position and rejects it with **error 5638
    "Invalid datatype specified."** Pass a **typed sentinel** (e.g. `"":U` for a CHARACTER
    diagnostic that is omitted downstream anyway) or a **conversion-function-wrapped unknown**
    (`STRING(?)`, `DATE(?)`, `INTEGER(?)`, …) so the argument's datatype is explicit. *(A bare `?`
    in a comparison (`x <> ?`) or assigned to a typed target is a different, fine idiom — this rule
    is specifically about `?` passed as a call argument.)*
  - Newer `Progress.Lang.*` / `OpenEdge.Core.*` / JSON-Object-Model members, constructors, or
    overloads added after 11.6; the `SERIALIZABLE` class attribute; later string-interpolation /
    pipe / generic-collection syntax. When in doubt, verify the member's introduced-version
    against the 11.6 ABL reference before using it.
  Because the dev machines have no `$DLC`, a clean compile is **[LIVE-ONLY]** (the 11.6 box is the
  final gate); these conventions catch the common breakages before they get there.
- **This repo is the only home for OpenEdge ABL/4GL.** ClearVue SaaS is .NET-only — no ABL
  belongs in the ClearVueSaaS repo. (The C# ConnectorAgent worker lives there; that's not ABL.)
- **Wire formats.** Dates are **ISO 8601** strings; decimals are **JSON numbers** (invariant
  `.` separator, no thousands separators) at the contract's per-field scale — never
  culture-formatted strings.
- **Read-only.** No code path may write to the ERP database. Use read-only DB connections.
- **Never commit QAD IP.** The MFG/PRO data dictionary (`*.df`) and any QAD schema source are
  excluded by `.gitignore` and must stay out of the repo. Referencing table/field names in
  queries is fine.
- **No secrets, no customer data.** API keys, connection strings, and captured customer
  responses do not belong in commits. `samples/` is gitignored unless a file is explicitly an
  `*.example.json` with scrubbed data.

## Naming & code conventions (OpenEdge)

Name with intent — the legacy `xx-####` 8.3 convention does **not** carry forward.

- **Prefer OOABL classes** over procedural `.p`; organize under a package namespace that
  mirrors the directory (e.g. `ClearVue.Connector.*`).
- **WebHandlers:** `<Resource>WebHandler` — e.g. `ProductStructureWebHandler`, `HealthWebHandler`.
- **Query / data access:** `<Entity>Query` holding the ported MFG/PRO joins — e.g.
  `ProductStructureQuery` (ports `xx-bmpsrp.p`), `ProductRouteQuery` (`xx-rorp.p`),
  `ProductCoverSheetQuery` (`xx-rprdcvr.p`).
- **Shared helpers:** descriptive — e.g. `DatabaseConnection.EnsureConnected()`, `ApiKeyAuthenticator`.
- **Temp-tables / datasets:** descriptive camelCase — `ttProductStructure`, `dsCoverSheet` — not `tt-ps`.
- **Methods / variables:** descriptive; no cryptic abbreviations, no `NEW SHARED` globals.
- The legacy procedures (`xx-*.p` in the Interact repo) are **reference only** — port the
  *logic*, give it an intentful home; never carry the legacy name forward.
- One responsibility per class/file; directory = namespace.

## Workflow

1. Open an issue describing the change.
2. For wire-visible changes, propose the `openapi/` edit alongside the implementation.
3. Keep PRs small and reviewable; explain how you tested against an OpenEdge 11.6 / PASOE
   instance.

## License

By contributing you agree your contributions are licensed under the project's
[Apache License 2.0](LICENSE).
