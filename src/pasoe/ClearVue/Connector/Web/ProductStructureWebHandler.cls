/*------------------------------------------------------------------------
    File        : ProductStructureWebHandler.cls
    Package     : ClearVue.Connector.Web
    Purpose     : GET /product-structure?part=&site=&correlationId=
                  The real POC slice: first query, flat JsonArray output,
                  wire formatting, auth, reconnect, and the contract error
                  model -- exercises every cross-cutting concern.

    Contract (clearvue-erp-connector.v1.yaml):
      200 -> StructureComponent[]  (empty array allowed when part has no comps)
      400 -> Error  (missing/invalid part or site)
      401 -> Error  (missing/invalid bearer)
      404 -> Error  (no record for part/site)
      502/503/504 -> Error (ERP query / connectivity / timeout)

    Order of operations:
      1. Enforce bearer auth (401 on mismatch) -- before any DB work.
      2. Validate part + site (400 if missing).
      3. EnsureConnected (pre-flight) then run the explosion.
      4. Mid-query disconnect -> reconnect + retry ONCE (resilience-and-errors
         §1 "Mid-query drop"); still failing -> structured 503/504.
      5. 0 rows -> 404; else compose the JsonArray and 200.

    JSON is hand-composed via the JSON Object Model (no WRITE-JSON, no string
    munging) so canonical field names + wire formats are exact.

    One responsibility: HTTP <-> structure query. Query logic lives in
    ProductStructureQuery; connection logic in DatabaseConnection; auth in
    ApiKeyAuthenticator; error shape in ConnectorError.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING OpenEdge.Web.WebResponse.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Core.String.
USING ClearVue.Connector.Config.ConnectorConfig.
USING ClearVue.Connector.Data.DatabaseConnection.
USING ClearVue.Connector.Security.ApiKeyAuthenticator.
USING ClearVue.Connector.Query.ProductStructureQuery.
USING ClearVue.Connector.Json.JsonFormat.
USING ClearVue.Connector.Web.ConnectorError.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Web.ProductStructureWebHandler INHERITS WebHandler:

    /* Per-field decimal scale per the contract (feasibility-11.6 §3). */
    DEFINE PRIVATE VARIABLE iQtyScale AS INTEGER NO-UNDO INITIAL 4.

    METHOD OVERRIDE PROTECTED INTEGER HandleGet(INPUT poRequest AS IWebRequest):
        DEFINE VARIABLE oConfig  AS ConnectorConfig     NO-UNDO.
        DEFINE VARIABLE oAuth    AS ApiKeyAuthenticator NO-UNDO.
        DEFINE VARIABLE oDb      AS DatabaseConnection  NO-UNDO.
        DEFINE VARIABLE oQuery   AS ProductStructureQuery NO-UNDO.
        DEFINE VARIABLE cPart    AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cSite    AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cCorrId  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iRows    AS INTEGER   NO-UNDO.

        oConfig = NEW ConnectorConfig().

        /* 1. auth first -- no DB work for an unauthorized caller */
        oAuth = NEW ApiKeyAuthenticator(oConfig).
        IF NOT oAuth:IsAuthorized(poRequest) THEN
            RETURN WriteError(ConnectorError:Unauthorized()).

        /* 2. params + validation */
        cPart   = GetQueryValue(poRequest, "part":U).
        cSite   = GetQueryValue(poRequest, "site":U).
        cCorrId = GetQueryValue(poRequest, "correlationId":U).

        IF cPart = "":U THEN
            RETURN WriteError(WithCorr(ConnectorError:BadRequest("part is required":U), cCorrId)).
        IF cSite = "":U THEN
            RETURN WriteError(WithCorr(ConnectorError:BadRequest("site is required":U), cCorrId)).

        /* 3-4. run with one reconnect-and-retry on a mid-query disconnect */
        oDb    = NEW DatabaseConnection(oConfig).
        oQuery = NEW ProductStructureQuery(oConfig, oDb).

        iRows = RunWithReconnect(oQuery, oDb, cPart, cSite).

        /* 5. 0 rows -> 404 (no structure for that part/site) */
        IF iRows = 0 THEN
            RETURN WriteError(WithCorr(
                ConnectorError:NotFound(
                    SUBSTITUTE("no product structure for part &1 at site &2":U, cPart, cSite)),
                cCorrId)).

        /* compose + 200 */
        RETURN WriteOk(ComposeArray(oQuery)).

        /* structured connector errors -> their mapped HTTP status + body */
        CATCH oCErr AS ConnectorError:
            RETURN WriteError(WithCorr(oCErr, cCorrId)).
        END CATCH.
        /* anything unexpected -> sanitized 500 */
        CATCH oErr AS Progress.Lang.Error:
            RETURN WriteError(WithCorr(
                ConnectorError:Internal(
                    IF oErr:NumMessages > 0 THEN oErr:GetMessage(1) ELSE "unexpected":U),
                cCorrId)).
        END CATCH.
    END METHOD.

    /* Pre-flight + run; on a mid-query disconnect, reconnect and retry ONCE.
       Lets non-disconnect ConnectorErrors propagate (404/400 don't retry). */
    METHOD PRIVATE INTEGER RunWithReconnect(INPUT poQuery AS ProductStructureQuery,
                                            INPUT poDb    AS DatabaseConnection,
                                            INPUT pcPart  AS CHARACTER,
                                            INPUT pcSite  AS CHARACTER):
        RETURN poQuery:Execute(pcPart, pcSite).

        CATCH oCErr AS ConnectorError:
            /* retry once only for a transient disconnect; re-prime the
               connection then re-run. EnsureConnected inside Execute throws
               again (mapped to 503/504) if the bounce can't be healed. */
            IF oCErr:Code = "ERP_DISCONNECTED":U THEN
            DO:
                poDb:EnsureConnected().    /* throws if still unhealable */
                RETURN poQuery:Execute(pcPart, pcSite).
            END.
            UNDO, THROW oCErr.
        END CATCH.
    END METHOD.

    /* Compose the contract StructureComponent[] from the query temp-table
       (accessed by HANDLE via a dynamic query). Canonical names + wire formats
       applied via JsonFormat. Rows come back in SeqNo (explosion) order. */
    METHOD PRIVATE JsonArray ComposeArray(INPUT poQuery AS ProductStructureQuery):
        DEFINE VARIABLE oArray  AS JsonArray  NO-UNDO.
        DEFINE VARIABLE oRow    AS JsonObject NO-UNDO.
        DEFINE VARIABLE hTable  AS HANDLE     NO-UNDO.
        DEFINE VARIABLE hBuffer AS HANDLE     NO-UNDO.
        DEFINE VARIABLE hQuery  AS HANDLE     NO-UNDO.

        oArray = NEW JsonArray().

        hTable  = poQuery:GetResultsHandle().
        hBuffer = hTable:DEFAULT-BUFFER-HANDLE.

        CREATE QUERY hQuery.
        hQuery:SET-BUFFERS(hBuffer).
        hQuery:QUERY-PREPARE("FOR EACH " + hBuffer:NAME + " NO-LOCK BY SeqNo":U).
        hQuery:QUERY-OPEN().

        hQuery:GET-FIRST().
        DO WHILE hBuffer:AVAILABLE:
            oRow = NEW JsonObject().
            /* PartNumber is required -> always present (never collapsed to null) */
            JsonFormat:AddString(oRow, "Level":U,
                hBuffer:BUFFER-FIELD("Level":U):BUFFER-VALUE).
            JsonFormat:AddString(oRow, "PartNumber":U,
                hBuffer:BUFFER-FIELD("PartNumber":U):BUFFER-VALUE).
            JsonFormat:AddStringOrNull(oRow, "Reference":U,
                hBuffer:BUFFER-FIELD("Reference":U):BUFFER-VALUE).
            JsonFormat:AddStringOrNull(oRow, "AltPartNumber":U,
                hBuffer:BUFFER-FIELD("AltPartNumber":U):BUFFER-VALUE).
            JsonFormat:AddStringOrNull(oRow, "Revision":U,
                hBuffer:BUFFER-FIELD("Revision":U):BUFFER-VALUE).
            JsonFormat:AddStringOrNull(oRow, "Description":U,
                hBuffer:BUFFER-FIELD("Description":U):BUFFER-VALUE).
            JsonFormat:AddNumber(oRow, "Quantity":U,
                hBuffer:BUFFER-FIELD("Quantity":U):BUFFER-VALUE, iQtyScale).
            JsonFormat:AddStringOrNull(oRow, "UnitOfMeasure":U,
                hBuffer:BUFFER-FIELD("UnitOfMeasure":U):BUFFER-VALUE).
            oArray:Add(oRow).

            hQuery:GET-NEXT().
        END.

        FINALLY:
            IF VALID-HANDLE(hQuery) THEN
            DO:
                IF hQuery:IS-OPEN THEN hQuery:QUERY-CLOSE().
                DELETE OBJECT hQuery.
            END.
        END FINALLY.

        RETURN oArray.
    END METHOD.

    /* ---- request helpers ---- */

    METHOD PRIVATE CHARACTER GetQueryValue(INPUT poRequest AS IWebRequest,
                                           INPUT pcName    AS CHARACTER):
        DEFINE VARIABLE cValue AS CHARACTER NO-UNDO.
        cValue = poRequest:URI:GetQueryValue(pcName) NO-ERROR.
        IF cValue = ? THEN cValue = "":U.
        RETURN TRIM(cValue).
    END METHOD.

    METHOD PRIVATE ConnectorError WithCorr(INPUT poErr AS ConnectorError,
                                           INPUT pcCorrId AS CHARACTER):
        IF pcCorrId <> "":U THEN
            poErr:CorrelationId = pcCorrId.
        RETURN poErr.
    END METHOD.

    /* ---- response writers ---- */

    METHOD PRIVATE INTEGER WriteOk(INPUT poArray AS JsonArray):
        DEFINE VARIABLE lcBody AS LONGCHAR NO-UNDO.
        poArray:Write(OUTPUT lcBody).
        RETURN WriteJson(INTEGER(StatusCodeEnum:OK), lcBody).
    END METHOD.

    METHOD PRIVATE INTEGER WriteError(INPUT poErr AS ConnectorError):
        DEFINE VARIABLE lcBody AS LONGCHAR NO-UNDO.
        poErr:ToJson():Write(OUTPUT lcBody).
        RETURN WriteJson(poErr:HttpStatus, lcBody).
    END METHOD.

    /* Canonical 11.6 response transmission via WebResponseWriter (Open/Close). */
    METHOD PRIVATE INTEGER WriteJson(INPUT piStatus AS INTEGER,
                                     INPUT plcBody   AS LONGCHAR):
        DEFINE VARIABLE oResponse AS WebResponse       NO-UNDO.
        DEFINE VARIABLE oWriter   AS WebResponseWriter NO-UNDO.
        DEFINE VARIABLE oBody     AS String            NO-UNDO.

        oBody = NEW String(plcBody).

        oResponse = NEW WebResponse().
        oResponse:StatusCode    = piStatus.
        oResponse:ContentType   = "application/json":U.
        oResponse:Entity        = oBody.
        oResponse:ContentLength = oBody:Size.

        oWriter = NEW WebResponseWriter(oResponse).
        oWriter:Open().
        oWriter:Close().
        RETURN 0.
    END METHOD.

END CLASS.
