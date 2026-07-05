@openapi.openedge.export FILE(type="REST", executionMode="external", useReturnValue="true", writeDataSetBeforeImage="false").
/* SPDX-License-Identifier: Apache-2.0 */

/*------------------------------------------------------------------------
    File        : GetProductCoverSheet.p
    Package     : ClearVue.Connector.Rest (REST-adapter entry seam)
    Purpose     : GET /product-cover-sheet entry point for the classic OpenEdge
                  REST adapter on the 11.6 target -- the richest operation
                  (header + structure + route + comments).

    Same binding rationale + thin-seam discipline as the sibling seams; all
    logic in the OOABL classes (ProductCoverSheetQuery, which reuses
    ProductStructureQuery + ProductRouteQuery; ProductCoverSheetJsonComposer;
    ApiKeyAuthenticator; DatabaseConnection; ConnectorError; ErrorClassifier;
    ConnectorLog). useReturnValue="true" -> RETURN the CHARACTER status code.

    SOL-119 is REUSED unchanged (via the sub-queries + EnsureConnected): a
    DB-down cover-sheet lookup returns the sanitized 503 ERP_CONNECTIVITY/
    retryable, raw detail logged server-side by correlationId.

    PARAMS (business vocabulary, aligned with the sibling endpoints):
      partNumber    QUERY   required
      facility      QUERY   required -- external facility code, mapped to site
      correlationId QUERY   optional -- generated when absent
      authHeader    HEADER  ("Authorization")
    OUTPUT:
      responseBody  LONGCHAR  the CoverSheet envelope (200) or the Error body.

    404 iff the part is absent from pt_mstr. A part that exists returns 200 with
    whatever header/structure/route/comments are available (arrays may be empty).
  ----------------------------------------------------------------------*/

BLOCK-LEVEL ON ERROR UNDO, THROW.

USING ClearVue.Connector.Config.ConnectorConfig.
USING ClearVue.Connector.Data.DatabaseConnection.
USING ClearVue.Connector.Security.ApiKeyAuthenticator.
USING ClearVue.Connector.Queries.ProductCoverSheetQuery.
USING ClearVue.Connector.Json.ProductCoverSheetJsonComposer.
USING ClearVue.Connector.Web.ConnectorError.
USING ClearVue.Connector.Web.ErrorClassifier.
USING ClearVue.Connector.Logging.ConnectorLog.

/* ---- mapped interface ---- */
DEFINE INPUT  PARAMETER partNumber    AS CHARACTER NO-UNDO.
DEFINE INPUT  PARAMETER facility      AS CHARACTER NO-UNDO.
DEFINE INPUT  PARAMETER correlationId AS CHARACTER NO-UNDO.
DEFINE INPUT  PARAMETER authHeader    AS CHARACTER NO-UNDO.
DEFINE OUTPUT PARAMETER responseBody  AS LONGCHAR  NO-UNDO.

/* ---- locals ---- */
DEFINE VARIABLE oConfig     AS ConnectorConfig              NO-UNDO.
DEFINE VARIABLE oAuth       AS ApiKeyAuthenticator          NO-UNDO.
DEFINE VARIABLE oDb         AS DatabaseConnection           NO-UNDO.
DEFINE VARIABLE oQuery      AS ProductCoverSheetQuery       NO-UNDO.
DEFINE VARIABLE oComposer   AS ProductCoverSheetJsonComposer NO-UNDO.
DEFINE VARIABLE oClassified AS ConnectorError               NO-UNDO.
DEFINE VARIABLE cSite       AS CHARACTER                    NO-UNDO.

/* ---- forward declarations ---- */
FUNCTION RunWithReconnect RETURNS LOGICAL
    (INPUT poQuery AS ProductCoverSheetQuery,
     INPUT poDb    AS DatabaseConnection,
     INPUT pcPart  AS CHARACTER,
     INPUT pcSite  AS CHARACTER) FORWARD.
FUNCTION WithCorr RETURNS ConnectorError (INPUT poErr AS ConnectorError) FORWARD.
FUNCTION FailWith RETURNS CHARACTER      (INPUT poErr AS ConnectorError) FORWARD.

oConfig = NEW ConnectorConfig().

/* 0. correlation id -- SOL-119: always have one. */
correlationId = TRIM(correlationId).
IF correlationId = ? OR correlationId = "":U THEN
    correlationId = GUID(GENERATE-UUID).

/* 1. auth first */
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

/* 2b. external facility code -> MFG/PRO site */
cSite = facility.

/* 3. pre-flight DB gate (SOL-119) */
oDb = NEW DatabaseConnection(oConfig).
oDb:EnsureConnected().

/* 4. assemble with one reconnect-and-retry on a mid-query disconnect */
oQuery = NEW ProductCoverSheetQuery(oConfig, oDb).
RunWithReconnect(oQuery, oDb, partNumber, cSite).

/* 5. part not in pt_mstr -> 404 */
IF NOT oQuery:PartExists() THEN
    RETURN FailWith(WithCorr(
        ConnectorError:NotFound(
            SUBSTITUTE("part &1 not found in ERP for facility &2":U, partNumber, facility)))).

/* part exists -> 200 with the composed CoverSheet envelope */
oComposer    = NEW ProductCoverSheetJsonComposer().
responseBody = oComposer:Compose(
                   INPUT oQuery:GetPartNumber(),
                   INPUT oQuery:GetHeaderHandle(),
                   INPUT oQuery:GetStructureHandle(),
                   INPUT oQuery:GetRouteHandle(),
                   INPUT oQuery:GetCommentsHandle()).
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

/* Assemble; on a transient disconnect, reconnect and retry ONCE. Returns TRUE
   on success (the query has no meaningful scalar return -- PartExists() carries
   the 404 decision). */
FUNCTION RunWithReconnect RETURNS LOGICAL
    (INPUT poQuery AS ProductCoverSheetQuery,
     INPUT poDb    AS DatabaseConnection,
     INPUT pcPart  AS CHARACTER,
     INPUT pcSite  AS CHARACTER):
    poQuery:Execute(pcPart, pcSite).
    RETURN TRUE.

    CATCH oCErr AS ConnectorError:
        IF oCErr:Code = "ERP_DISCONNECTED":U OR oCErr:Code = "ERP_UNAVAILABLE":U THEN
        DO:
            poDb:EnsureConnected().    /* throws (->503/504) if still unhealable */
            poQuery:Execute(pcPart, pcSite).
            RETURN TRUE.
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
