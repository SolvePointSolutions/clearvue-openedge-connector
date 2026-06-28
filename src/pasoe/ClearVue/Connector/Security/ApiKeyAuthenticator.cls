/*------------------------------------------------------------------------
    File        : ApiKeyAuthenticator.cls
    Package     : ClearVue.Connector.Security
    Purpose     : Enforce the contract's BearerAuth scheme in the WebHandler.

    Reads `Authorization: Bearer <key>` from the request and compares the
    presented key to the configured shared secret (ConnectorConfig:GetApiKey,
    sourced from the environment / OS secret store -- never source). Returns
    TRUE only on an exact match.

    Fail closed: if no secret is configured, NOTHING authorizes (an unset key
    must never become an open door).

    One responsibility: bearer credential check. No DB, no JSON, no routing.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.IWebRequest.
USING OpenEdge.Net.HTTP.HttpHeader.
USING ClearVue.Connector.Config.ConnectorConfig.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Security.ApiKeyAuthenticator:

    DEFINE PRIVATE VARIABLE oConfig AS ConnectorConfig NO-UNDO.

    CONSTRUCTOR PUBLIC ApiKeyAuthenticator(INPUT poConfig AS ConnectorConfig):
        ASSIGN oConfig = poConfig.
    END CONSTRUCTOR.

    /* TRUE iff the request carries a valid bearer token matching the secret. */
    METHOD PUBLIC LOGICAL IsAuthorized(INPUT poRequest AS IWebRequest):
        DEFINE VARIABLE oHeader    AS HttpHeader NO-UNDO.
        DEFINE VARIABLE cHeader    AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cPresented AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cSecret    AS CHARACTER  NO-UNDO.

        cSecret = oConfig:GetApiKey().

        /* fail closed: no configured secret => deny everything */
        IF cSecret = ? OR cSecret = "":U THEN
            RETURN FALSE.

        /* GetHeader returns an HttpHeader object on 11.6; read its :Value.
           HasHeader guards the absent-header case (GetHeader can throw/return
           a sentinel when the header is missing). */
        IF NOT poRequest:HasHeader("Authorization":U) THEN
            RETURN FALSE.

        oHeader = poRequest:GetHeader("Authorization":U) NO-ERROR.
        IF NOT VALID-OBJECT(oHeader) THEN
            RETURN FALSE.

        cHeader = oHeader:Value.
        IF cHeader = ? OR cHeader = "":U THEN
            RETURN FALSE.

        cPresented = ExtractBearer(cHeader).
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
