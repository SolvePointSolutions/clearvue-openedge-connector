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
    The .p instantiates/calls them; it does NOT inline their logic.

    HTTP STATUS: useReturnValue="true" (annotation above) maps this procedure's
    RETURN value to the HTTP response status line. We RETURN the status code as
    a CHARACTER ("200"/"400"/"401"/"404"/"502"/"503"/"504"), so the contract's
    real status codes are set from the .p -- not crammed into the body.

    AUTH HEADER: the inbound `Authorization` header is surfaced to the .p as the
    `authorization` INPUT param, mapped in the REST resource as a HEADER param
    (see config/resourceModel.example.xml). PASOE may strip Authorization for
    Web handlers, but the classic REST adapter can map it to a CHARACTER param.

    PARAMS (mapped in the REST resource):
      part          QUERY   required
      site          QUERY   required
      correlationId QUERY   optional
      authorization HEADER  ("Authorization")
    OUTPUT:
      responseBody  LONGCHAR  the JSON array (200) or the contract Error body.
  ----------------------------------------------------------------------*/

BLOCK-LEVEL ON ERROR UNDO, THROW.

USING ClearVue.Connector.Config.ConnectorConfig.
USING ClearVue.Connector.Data.DatabaseConnection.
USING ClearVue.Connector.Security.ApiKeyAuthenticator.
USING ClearVue.Connector.Query.ProductStructureQuery.
USING ClearVue.Connector.Json.ProductStructureJsonComposer.
USING ClearVue.Connector.Web.ConnectorError.

/* ---- mapped interface ---- */
DEFINE INPUT  PARAMETER part          AS CHARACTER NO-UNDO.
DEFINE INPUT  PARAMETER site          AS CHARACTER NO-UNDO.
DEFINE INPUT  PARAMETER correlationId AS CHARACTER NO-UNDO.
DEFINE INPUT  PARAMETER authorization AS CHARACTER NO-UNDO.
DEFINE OUTPUT PARAMETER responseBody  AS LONGCHAR  NO-UNDO.

/* ---- locals ---- */
DEFINE VARIABLE oConfig   AS ConnectorConfig             NO-UNDO.
DEFINE VARIABLE oAuth     AS ApiKeyAuthenticator         NO-UNDO.
DEFINE VARIABLE oDb       AS DatabaseConnection          NO-UNDO.
DEFINE VARIABLE oQuery    AS ProductStructureQuery       NO-UNDO.
DEFINE VARIABLE oComposer AS ProductStructureJsonComposer NO-UNDO.
DEFINE VARIABLE iRows     AS INTEGER                     NO-UNDO.

/* ---- forward declarations (functions defined after the main block) ---- */
FUNCTION RunWithReconnect RETURNS INTEGER
    (INPUT poQuery AS ProductStructureQuery,
     INPUT poDb    AS DatabaseConnection,
     INPUT pcPart  AS CHARACTER,
     INPUT pcSite  AS CHARACTER) FORWARD.
FUNCTION WithCorr  RETURNS ConnectorError (INPUT poErr AS ConnectorError) FORWARD.
FUNCTION FailWith  RETURNS CHARACTER      (INPUT poErr AS ConnectorError) FORWARD.

oConfig = NEW ConnectorConfig().

/* 1. auth first -- no DB work for an unauthorized caller */
oAuth = NEW ApiKeyAuthenticator(oConfig).
IF NOT oAuth:IsAuthorizedHeader(authorization) THEN
    RETURN FailWith(ConnectorError:Unauthorized()).

/* 2. validate params */
ASSIGN
    part = TRIM(part)
    site = TRIM(site).
IF part = "":U THEN
    RETURN FailWith(WithCorr(ConnectorError:BadRequest("part is required":U))).
IF site = "":U THEN
    RETURN FailWith(WithCorr(ConnectorError:BadRequest("site is required":U))).

/* 3-4. run with one reconnect-and-retry on a mid-query disconnect */
oDb    = NEW DatabaseConnection(oConfig).
oQuery = NEW ProductStructureQuery(oConfig, oDb).
iRows  = RunWithReconnect(oQuery, oDb, part, site).

/* 5. 0 rows -> 404, else compose + 200 */
IF iRows = 0 THEN
    RETURN FailWith(WithCorr(
        ConnectorError:NotFound(
            SUBSTITUTE("no product structure for part &1 at site &2":U, part, site)))).

oComposer    = NEW ProductStructureJsonComposer().
responseBody = oComposer:Compose(oQuery:GetResultsHandle()).
RETURN "200":U.

/* ---- structured + unexpected error mapping -> status via RETURN ---- */
CATCH oCErr AS ConnectorError:
    RETURN FailWith(WithCorr(oCErr)).
END CATCH.
CATCH oErr AS Progress.Lang.Error:
    RETURN FailWith(WithCorr(
        ConnectorError:Internal(
            IF oErr:NumMessages > 0 THEN oErr:GetMessage(1) ELSE "unexpected":U))).
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
        IF oCErr:Code = "ERP_DISCONNECTED":U THEN
        DO:
            poDb:EnsureConnected().    /* throws (->503/504) if still unhealable */
            RETURN poQuery:Execute(pcPart, pcSite).
        END.
        UNDO, THROW oCErr.
    END CATCH.
END FUNCTION.

/* Stamp the optional correlation id onto an error. */
FUNCTION WithCorr RETURNS ConnectorError
    (INPUT poErr AS ConnectorError):
    IF correlationId <> ? AND TRIM(correlationId) <> "":U THEN
        poErr:CorrelationId = TRIM(correlationId).
    RETURN poErr.
END FUNCTION.

/* Render the error body to the OUTPUT param and yield the status code string
   the REST adapter maps to the HTTP status line. */
FUNCTION FailWith RETURNS CHARACTER
    (INPUT poErr AS ConnectorError):
    responseBody = poErr:ToJsonString().
    RETURN poErr:StatusString().
END FUNCTION.
