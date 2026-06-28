/*------------------------------------------------------------------------
    File        : ApiKeyAuthenticator.cls
    Package     : ClearVue.Connector.Security
    Purpose     : Enforce the contract's BearerAuth scheme.

    Compares the presented `Authorization: Bearer <key>` value to the configured
    shared secret (ConnectorConfig:GetApiKey, sourced from the environment / OS
    secret store -- never source). Returns TRUE only on an exact match.

    Transport-agnostic by design. In the OpenEdge 11.6 target the REST entry is
    a mapped .p (classic REST adapter), so the inbound Authorization header is
    surfaced to the .p as a CHARACTER input param and passed to
    IsAuthorizedHeader(). The core bearer-extraction + fail-closed logic lives
    here once; the .p does no auth logic of its own.

    Fail closed: if no secret is configured, NOTHING authorizes (an unset key
    must never become an open door).

    One responsibility: bearer credential check. No DB, no JSON, no routing.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING ClearVue.Connector.Config.ConnectorConfig.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Security.ApiKeyAuthenticator:

    DEFINE PRIVATE VARIABLE oConfig AS ConnectorConfig NO-UNDO.

    CONSTRUCTOR PUBLIC ApiKeyAuthenticator(INPUT poConfig AS ConnectorConfig):
        ASSIGN oConfig = poConfig.
    END CONSTRUCTOR.

    /* THE entry point for the .p model: validate a raw Authorization header
       value (e.g. "Bearer abc123") mapped from the REST request to a param.
       TRUE iff it carries a bearer token matching the configured secret. */
    METHOD PUBLIC LOGICAL IsAuthorizedHeader(INPUT pcAuthHeader AS CHARACTER):
        DEFINE VARIABLE cPresented AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cSecret    AS CHARACTER NO-UNDO.

        cSecret = oConfig:GetApiKey().

        /* fail closed: no configured secret => deny everything */
        IF cSecret = ? OR cSecret = "":U THEN
            RETURN FALSE.

        IF pcAuthHeader = ? OR pcAuthHeader = "":U THEN
            RETURN FALSE.

        cPresented = ExtractBearer(pcAuthHeader).
        IF cPresented = "":U THEN
            RETURN FALSE.

        RETURN cPresented = cSecret.
    END METHOD.

    /* Pull the token out of "Bearer <token>" (scheme name case-insensitive). */
    METHOD PRIVATE CHARACTER ExtractBearer(INPUT pcHeader AS CHARACTER):
        DEFINE VARIABLE cScheme AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cToken  AS CHARACTER NO-UNDO.

        cScheme = ENTRY(1, TRIM(pcHeader), " ":U) NO-ERROR.
        IF cScheme = ? THEN RETURN "":U.

        IF LC(cScheme) <> "bearer":U THEN
            RETURN "":U.

        /* everything after the first space is the token */
        cToken = TRIM(SUBSTRING(TRIM(pcHeader), LENGTH(cScheme) + 2)).
        RETURN cToken.
    END METHOD.

END CLASS.
