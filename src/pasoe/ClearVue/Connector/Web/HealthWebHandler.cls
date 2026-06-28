/*------------------------------------------------------------------------
    File        : HealthWebHandler.cls
    Package     : ClearVue.Connector.Web
    Purpose     : GET /health -- liveness/readiness. The walking-skeleton
                  step 0: proves the PASOE deploy, the DB connection path, and
                  the JSON composition are all wired before any real query.

    Contract (clearvue-erp-connector.v1.yaml #/Health, security: []):
      { "service": <name>, "version": <ver>, "erpReachable": <bool> }

    Auth: the contract marks /health as security:[] (no auth) so a load
    balancer / the agent can probe liveness without a token. We still run a
    lightweight, non-throwing DB probe to populate erpReachable -- a failed
    probe is reported as erpReachable:false, NOT a 5xx (health stays 200 so
    liveness is distinguishable from ERP reachability).

    One responsibility: render health. No query logic, no auth enforcement.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING OpenEdge.Web.WebResponse.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Core.String.
USING ClearVue.Connector.Config.ConnectorConfig.
USING ClearVue.Connector.Data.DatabaseConnection.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Web.HealthWebHandler INHERITS WebHandler:

    DEFINE PRIVATE VARIABLE cServiceName AS CHARACTER NO-UNDO
        INITIAL "clearvue-openedge-connector":U.
    DEFINE PRIVATE VARIABLE cVersion AS CHARACTER NO-UNDO
        INITIAL "1.0.0":U.

    METHOD OVERRIDE PROTECTED INTEGER HandleGet(INPUT poRequest AS IWebRequest):
        DEFINE VARIABLE oConfig   AS ConnectorConfig    NO-UNDO.
        DEFINE VARIABLE oDb       AS DatabaseConnection NO-UNDO.
        DEFINE VARIABLE oJson     AS JsonObject         NO-UNDO.
        DEFINE VARIABLE lReach    AS LOGICAL            NO-UNDO.

        oConfig = NEW ConnectorConfig().
        oDb     = NEW DatabaseConnection(oConfig).

        /* lightweight, non-throwing reachability probe */
        lReach = oDb:ProbeReachable() NO-ERROR.

        oJson = NEW JsonObject().
        oJson:Add("service":U,      cServiceName).
        oJson:Add("version":U,      cVersion).
        oJson:Add("erpReachable":U, lReach).

        RETURN WriteJson(INTEGER(StatusCodeEnum:OK), oJson).
    END METHOD.

    /* Shared JSON writer: sets status, content-type, body. Uses the canonical
       11.6 WebResponseWriter (Open/Close) to transmit the response. */
    METHOD PRIVATE INTEGER WriteJson(INPUT piStatus AS INTEGER,
                                     INPUT poJson    AS JsonObject):
        DEFINE VARIABLE oResponse AS WebResponse       NO-UNDO.
        DEFINE VARIABLE oWriter   AS WebResponseWriter NO-UNDO.
        DEFINE VARIABLE oBody     AS String            NO-UNDO.
        DEFINE VARIABLE lcBody    AS LONGCHAR          NO-UNDO.

        poJson:Write(OUTPUT lcBody).
        oBody = NEW String(lcBody).

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
