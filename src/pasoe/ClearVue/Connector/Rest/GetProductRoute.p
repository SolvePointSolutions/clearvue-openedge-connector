@openapi.openedge.export FILE(type="REST", executionMode="external", useReturnValue="true", writeDataSetBeforeImage="false").
/* SPDX-License-Identifier: Apache-2.0 */

/*------------------------------------------------------------------------
    File        : GetProductRoute.p
    Package     : ClearVue.Connector.Rest (REST-adapter entry seam)
    Purpose     : GET /product-route entry point for the classic OpenEdge REST
                  adapter on the 11.6 target.

    Same binding rationale + thin-seam discipline as GetProductStructure.p: the
    resource URI maps to this annotated .p (not a WebHandler); all logic lives in
    the OOABL classes (ProductRouteQuery, ProductRouteJsonComposer,
    ApiKeyAuthenticator, DatabaseConnection, ConnectorError, ErrorClassifier,
    ConnectorLog). useReturnValue="true" -> RETURN the CHARACTER status code.

    SOL-119 is REUSED here unchanged: the same ErrorClassifier + ConnectorLog +
    bounded EnsureConnected() reconnect apply, so a DB-down route lookup returns
    503 ERP_CONNECTIVITY/retryable with a sanitized diagnostic, raw detail logged
    server-side by correlationId.

    PARAMS (mapped in the REST resource) -- ClearVue business vocabulary,
    aligned with /product-structure (Rod, 2026-07-05):
      partNumber    QUERY   required -- the part identifier to look up.
      facility      QUERY   required -- the EXTERNAL FACILITY CODE the ERP uses
                            to identify the location (a string, e.g. "1000"); NOT
                            a ClearVue Guid. Mapped to the MFG/PRO site below.
                            `domain` is NOT a param -- it is connector CONFIG.
      correlationId QUERY   optional -- generated when absent; echoed in errors
                            and keys the server-side raw-diagnostic log.
      authHeader    HEADER  ("Authorization"; NOT `authorization`, a reserved word)
    OUTPUT:
      responseBody  LONGCHAR  the RouteStep[] array (200) or the Error body.

    404 vs 200-empty: 404 iff the part is absent from pt_mstr (PartExists()
    FALSE). A part that exists but has no routing returns 200 with an EMPTY
    array -- never a 404, never a synthetic "routing not found" row.
  ----------------------------------------------------------------------*/

BLOCK-LEVEL ON ERROR UNDO, THROW.

USING ClearVue.Connector.Config.ConnectorConfig.
USING ClearVue.Connector.Data.DatabaseConnection.
USING ClearVue.Connector.Security.ApiKeyAuthenticator.
USING ClearVue.Connector.Queries.ProductRouteQuery.
USING ClearVue.Connector.Json.ProductRouteJsonComposer.
USING ClearVue.Connector.Web.ConnectorError.
USING ClearVue.Connector.Web.ErrorClassifier.
USING ClearVue.Connector.Logging.ConnectorLog.

/* ---- mapped interface (business vocabulary: partNumber / facility) ---- */
DEFINE INPUT  PARAMETER partNumber    AS CHARACTER NO-UNDO.
DEFINE INPUT  PARAMETER facility      AS CHARACTER NO-UNDO.
DEFINE INPUT  PARAMETER correlationId AS CHARACTER NO-UNDO.
DEFINE INPUT  PARAMETER authHeader    AS CHARACTER NO-UNDO.
DEFINE OUTPUT PARAMETER responseBody  AS LONGCHAR  NO-UNDO.

/* ---- locals ---- */
DEFINE VARIABLE oConfig     AS ConnectorConfig          NO-UNDO.
DEFINE VARIABLE oAuth       AS ApiKeyAuthenticator      NO-UNDO.
DEFINE VARIABLE oDb         AS DatabaseConnection       NO-UNDO.
DEFINE VARIABLE oQuery      AS ProductRouteQuery        NO-UNDO.
DEFINE VARIABLE oComposer   AS ProductRouteJsonComposer NO-UNDO.
DEFINE VARIABLE oClassified AS ConnectorError           NO-UNDO.
DEFINE VARIABLE iRows       AS INTEGER                  NO-UNDO.
/* cSite: the MFG/PRO site the ERP query keys on (the wire speaks `facility`,
   the external facility code; this is the internal ERP-vocabulary target). */
DEFINE VARIABLE cSite       AS CHARACTER                NO-UNDO.

/* ---- forward declarations ---- */
FUNCTION RunWithReconnect RETURNS INTEGER
    (INPUT poQuery AS ProductRouteQuery,
     INPUT poDb    AS DatabaseConnection,
     INPUT pcPart  AS CHARACTER,
     INPUT pcSite  AS CHARACTER) FORWARD.
FUNCTION WithCorr RETURNS ConnectorError (INPUT poErr AS ConnectorError) FORWARD.
FUNCTION FailWith RETURNS CHARACTER      (INPUT poErr AS ConnectorError) FORWARD.

oConfig = NEW ConnectorConfig().

/* 0. correlation id -- SOL-119: always have one (caller-supplied or generated). */
correlationId = TRIM(correlationId).
IF correlationId = ? OR correlationId = "":U THEN
    correlationId = GUID(GENERATE-UUID).

/* 1. auth first -- no DB work for an unauthorized caller */
oAuth = NEW ApiKeyAuthenticator(oConfig).
IF NOT oAuth:IsAuthorizedHeader(authHeader) THEN
    RETURN FailWith(WithCorr(ConnectorError:Unauthorized())).

/* 2. validate params */
ASSIGN
    partNumber = TRIM(partNumber)
    facility   = TRIM(facility).
IF partNumber = "":U THEN
    RETURN FailWith(WithCorr(ConnectorError:BadRequest("partNumber is required":U))).
IF facility = "":U THEN
    RETURN FailWith(WithCorr(ConnectorError:BadRequest("facility is required":U))).

/* 2b. map external facility code -> MFG/PRO site (direct for QAD MFG/PRO). */
cSite = facility.

/* 3. pre-flight the DB gate BEFORE the query class touches the schema (SOL-119). */
oDb = NEW DatabaseConnection(oConfig).
oDb:EnsureConnected().

/* 4. run with one reconnect-and-retry on a mid-query disconnect. (row count
      captured but not used for control flow -- the 404 decision is PartExists();
      assigned because ABL consumes a user-defined function's return value.) */
oQuery = NEW ProductRouteQuery(oConfig, oDb).
iRows  = RunWithReconnect(oQuery, oDb, partNumber, cSite).

/* 5. part not in pt_mstr -> 404 (genuinely not found in the ERP). A part that
      exists with no routing returns 200 with an empty array below. */
IF NOT oQuery:PartExists() THEN
    RETURN FailWith(WithCorr(
        ConnectorError:NotFound(
            SUBSTITUTE("part &1 not found in ERP for facility &2":U, partNumber, facility)))).

/* part exists -> 200 with the RouteStep[] array (empty when no routing) */
oComposer    = NEW ProductRouteJsonComposer().
responseBody = oComposer:Compose(oQuery:GetResultsHandle()).
RETURN "200":U.

/* ---- structured + unexpected error mapping -> status via RETURN ---- */
CATCH oCErr AS ConnectorError:
    RETURN FailWith(WithCorr(oCErr)).
END CATCH.
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

/* Pre-flight + run; on a transient disconnect, reconnect and retry ONCE. */
FUNCTION RunWithReconnect RETURNS INTEGER
    (INPUT poQuery AS ProductRouteQuery,
     INPUT poDb    AS DatabaseConnection,
     INPUT pcPart  AS CHARACTER,
     INPUT pcSite  AS CHARACTER):
    RETURN poQuery:Execute(pcPart, pcSite).

    CATCH oCErr AS ConnectorError:
        IF oCErr:Code = "ERP_DISCONNECTED":U OR oCErr:Code = "ERP_UNAVAILABLE":U THEN
        DO:
            poDb:EnsureConnected().    /* throws (->503/504) if still unhealable */
            RETURN poQuery:Execute(pcPart, pcSite).
        END.
        UNDO, THROW oCErr.
    END CATCH.
END FUNCTION.

/* Stamp the correlation id onto an error. */
FUNCTION WithCorr RETURNS ConnectorError
    (INPUT poErr AS ConnectorError):
    IF correlationId <> ? AND TRIM(correlationId) <> "":U THEN
        poErr:CorrelationId = TRIM(correlationId).
    RETURN poErr.
END FUNCTION.

/* Render the error body + yield the status code; SOL-119 server-side log point. */
FUNCTION FailWith RETURNS CHARACTER
    (INPUT poErr AS ConnectorError):
    ConnectorLog:WriteError(poErr:CorrelationId, poErr:Code, poErr:RawDetail).
    responseBody = poErr:ToJsonString().
    RETURN poErr:StatusString().
END FUNCTION.
