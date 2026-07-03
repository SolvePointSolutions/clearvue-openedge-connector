@openapi.openedge.export FILE(type="REST", executionMode="external", useReturnValue="true", writeDataSetBeforeImage="false").

/*------------------------------------------------------------------------
    File        : GetProductStructure.p
    Package     : ClearVue.Connector.Rest (REST-adapter entry seam)
    Purpose     : GET /product-structure entry point for the CLASSIC OpenEdge
                  REST adapter on the 11.6 target.

    WHY A .p AND NOT A WebHandler: on OpenEdge 11.6 the REST resource URI maps
    to an annotated procedure with mapped INPUT/OUTPUT params -- you cannot bind
    an OpenEdge.Web.WebHandler class directly to the resource URI (authoritative
    per Rod's live 11.6 box). See docs/feasibility-11.6.md (binding model:
    WebHandler -> classic REST adapter .p).

    THIS .p IS A THIN SEAM ONLY. All logic stays in the OOABL classes:
      - ApiKeyAuthenticator         bearer check (header value passed in)
      - DatabaseConnection          EnsureConnected() reconnect
      - ProductStructureQuery       the ported BOM explosion
      - ProductStructureJsonComposer hand-composed contract JSON
      - ConnectorError              contract Error body + status mapping
      - ErrorClassifier             SOL-119 connection-state classification
      - ConnectorLog                SOL-119 server-side raw-diagnostic log
    The .p instantiates/calls them; it does NOT inline their logic.

    HTTP STATUS: useReturnValue="true" (annotation above) maps this procedure's
    RETURN value to the HTTP response status line. We RETURN the status code as
    a CHARACTER ("200"/"400"/"401"/"404"/"502"/"503"/"504"), so the contract's
    real status codes are set from the .p -- not crammed into the body.

    AUTH HEADER: the inbound `Authorization` header is surfaced to the .p as the
    `authHeader` INPUT param (NOT `authorization` -- that is a RESERVED ABL
    keyword and will not compile), mapped in the REST resource as a HEADER param
    (see config/resourceModel.example.xml). PASOE may strip Authorization for
    Web handlers, but the classic REST adapter can map it to a CHARACTER param.

    PARAMS (mapped in the REST resource):
      part          QUERY   required
      site          QUERY   required
      correlationId QUERY   optional -- SOL-119: the connector GENERATES a
                            GUID when absent, echoes it in every Error body,
                            and keys the server-side raw-diagnostic log line
                            (ConnectorLog) by it.
      authHeader    HEADER  ("Authorization")
    OUTPUT:
      responseBody  LONGCHAR  the JSON array (200) or the contract Error body.
  ----------------------------------------------------------------------*/

BLOCK-LEVEL ON ERROR UNDO, THROW.

USING ClearVue.Connector.Config.ConnectorConfig.
USING ClearVue.Connector.Data.DatabaseConnection.
USING ClearVue.Connector.Security.ApiKeyAuthenticator.
USING ClearVue.Connector.Queries.ProductStructureQuery.
USING ClearVue.Connector.Json.ProductStructureJsonComposer.
USING ClearVue.Connector.Web.ConnectorError.
USING ClearVue.Connector.Web.ErrorClassifier.
USING ClearVue.Connector.Logging.ConnectorLog.

/* ---- mapped interface ---- */
DEFINE INPUT  PARAMETER part          AS CHARACTER NO-UNDO.
DEFINE INPUT  PARAMETER site          AS CHARACTER NO-UNDO.
DEFINE INPUT  PARAMETER correlationId AS CHARACTER NO-UNDO.
/* NB: the param is authHeader, NOT `authorization` -- AUTHORIZATION is a
   RESERVED ABL keyword on 11.6, so a param/variable named `authorization`
   fails to compile (254/247). The inbound HTTP header is still "Authorization";
   only the ABL identifier differs. The REST mapping binds headerName=
   "Authorization" to this param via name="authHeader". */
DEFINE INPUT  PARAMETER authHeader    AS CHARACTER NO-UNDO.
DEFINE OUTPUT PARAMETER responseBody  AS LONGCHAR  NO-UNDO.

/* ---- locals ---- */
DEFINE VARIABLE oConfig     AS ConnectorConfig             NO-UNDO.
DEFINE VARIABLE oAuth       AS ApiKeyAuthenticator         NO-UNDO.
DEFINE VARIABLE oDb         AS DatabaseConnection          NO-UNDO.
DEFINE VARIABLE oQuery      AS ProductStructureQuery       NO-UNDO.
DEFINE VARIABLE oComposer   AS ProductStructureJsonComposer NO-UNDO.
DEFINE VARIABLE iRows       AS INTEGER                     NO-UNDO.
DEFINE VARIABLE oClassified AS ConnectorError              NO-UNDO.

/* ---- forward declarations (functions defined after the main block) ---- */
FUNCTION RunWithReconnect RETURNS INTEGER
    (INPUT poQuery AS ProductStructureQuery,
     INPUT poDb    AS DatabaseConnection,
     INPUT pcPart  AS CHARACTER,
     INPUT pcSite  AS CHARACTER) FORWARD.
FUNCTION WithCorr  RETURNS ConnectorError (INPUT poErr AS ConnectorError) FORWARD.
FUNCTION FailWith  RETURNS CHARACTER      (INPUT poErr AS ConnectorError) FORWARD.

oConfig = NEW ConnectorConfig().

/* 0. correlation id -- SOL-119: ALWAYS have one. Caller-supplied wins;
   otherwise the connector generates a GUID so every error envelope carries
   a correlationId that resolves to the raw diagnostic in the connector log
   (ConnectorLog writes it; the raw detail never crosses the wire). */
correlationId = TRIM(correlationId).
IF correlationId = ? OR correlationId = "":U THEN
    correlationId = GUID(GENERATE-UUID).

/* 1. auth first -- no DB work for an unauthorized caller */
oAuth = NEW ApiKeyAuthenticator(oConfig).
IF NOT oAuth:IsAuthorizedHeader(authHeader) THEN
    RETURN FailWith(WithCorr(ConnectorError:Unauthorized())).

/* 2. validate params */
ASSIGN
    part = TRIM(part)
    site = TRIM(site).
IF part = "":U THEN
    RETURN FailWith(WithCorr(ConnectorError:BadRequest("part is required":U))).
IF site = "":U THEN
    RETURN FailWith(WithCorr(ConnectorError:BadRequest("site is required":U))).

/* 3. pre-flight the DB gate BEFORE instantiating the query class (SOL-119).
   ProductStructureQuery's r-code references the ERP schema (pt_mstr/ps_mstr/
   ...), so with the DB down the NEW itself raises raw OE error 1006
   ("Database <name> not connected.") before Execute()/EnsureConnected() ever
   runs -- that raw fault is what previously fell into the generic catch-all
   as INTERNAL/500. Gating here means a stopped DB takes the structured
   reconnect path (-> 503 retryable) instead. */
oDb = NEW DatabaseConnection(oConfig).
oDb:EnsureConnected().

/* 4. run with one reconnect-and-retry on a mid-query disconnect */
oQuery = NEW ProductStructureQuery(oConfig, oDb).
iRows  = RunWithReconnect(oQuery, oDb, part, site).

/* 5. 0 rows -> 404 (part NOT in pt_mstr -- genuinely not found in the ERP).
      A part that exists but has no BOM returns >=1 row (the root row) and 200,
      NOT 404 -- see ProductStructureQuery's existence gate. */
IF iRows = 0 THEN
    RETURN FailWith(WithCorr(
        ConnectorError:NotFound(
            SUBSTITUTE("part &1 not found in ERP for site &2":U, part, site)))).

/* part exists -> 200 with the root row (plus children if any) */
oComposer    = NEW ProductStructureJsonComposer().
responseBody = oComposer:Compose(oQuery:GetResultsHandle()).
RETURN "200":U.

/* ---- structured + unexpected error mapping -> status via RETURN ---- */
CATCH oCErr AS ConnectorError:
    RETURN FailWith(WithCorr(oCErr)).
END CATCH.
/* SOL-119: classification step BEFORE the generic catch-all verdict. A known
   OpenEdge connection-state fault (db not connected / broker down / lost
   connection / connect refused) becomes 503 ERP_CONNECTIVITY retryable with
   a sanitized reason. Only a genuinely unknown fault stays INTERNAL/500/
   non-retryable -- and its wire diagnostic is now sanitized too: the raw
   message (class names, db name, OE error numbers) goes to the connector
   log via FailWith, keyed by the correlationId echoed in the envelope. */
CATCH oErr AS Progress.Lang.Error:
    oClassified = ErrorClassifier:ClassifyConnectionState(oErr).
    IF NOT VALID-OBJECT(oClassified) THEN
    DO:
        oClassified = ConnectorError:Internal(
            "unexpected connector fault; quote the correlationId to support":U).
        oClassified:RawDetail = ErrorClassifier:RawDetailOf(oErr).
    END.
    RETURN FailWith(WithCorr(oClassified)).
END CATCH.

/* ---- internal procedures (thin glue; no business logic) ---- */

/* Pre-flight + run; on a transient disconnect, reconnect and retry ONCE.
   Non-disconnect ConnectorErrors propagate (404/400 don't retry). */
FUNCTION RunWithReconnect RETURNS INTEGER
    (INPUT poQuery AS ProductStructureQuery,
     INPUT poDb    AS DatabaseConnection,
     INPUT pcPart  AS CHARACTER,
     INPUT pcSite  AS CHARACTER):
    RETURN poQuery:Execute(pcPart, pcSite).

    CATCH oCErr AS ConnectorError:
        /* retry once on either transient connection-state code (SOL-119:
           the classifier can surface ERP_UNAVAILABLE mid-query too) */
        IF oCErr:Code = "ERP_DISCONNECTED":U OR oCErr:Code = "ERP_UNAVAILABLE":U THEN
        DO:
            poDb:EnsureConnected().    /* throws (->503/504) if still unhealable */
            RETURN poQuery:Execute(pcPart, pcSite).
        END.
        UNDO, THROW oCErr.
    END CATCH.
END FUNCTION.

/* Stamp the correlation id onto an error (always present -- caller-supplied
   or connector-generated at step 0). */
FUNCTION WithCorr RETURNS ConnectorError
    (INPUT poErr AS ConnectorError):
    IF correlationId <> ? AND TRIM(correlationId) <> "":U THEN
        poErr:CorrelationId = TRIM(correlationId).
    RETURN poErr.
END FUNCTION.

/* Render the error body to the OUTPUT param and yield the status code string
   the REST adapter maps to the HTTP status line. SOL-119: this is also the
   single server-side logging point -- any raw detail carried on the error
   (never serialized) is written to the connector log keyed by the
   correlationId before the sanitized envelope goes on the wire. */
FUNCTION FailWith RETURNS CHARACTER
    (INPUT poErr AS ConnectorError):
    ConnectorLog:WriteError(poErr:CorrelationId, poErr:Code, poErr:RawDetail).
    responseBody = poErr:ToJsonString().
    RETURN poErr:StatusString().
END FUNCTION.
