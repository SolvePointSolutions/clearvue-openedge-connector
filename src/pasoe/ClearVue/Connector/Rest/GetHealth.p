@openapi.openedge.export FILE(type="REST", executionMode="external", useReturnValue="true", writeDataSetBeforeImage="false").

/*------------------------------------------------------------------------
    File        : GetHealth.p
    Package     : ClearVue.Connector.Rest (REST-adapter entry seam)
    Purpose     : GET /health entry point for the classic OpenEdge REST adapter.

    Same binding rationale as GetProductStructure.p: on 11.6 the resource URI
    maps to this annotated .p, not to a WebHandler class.

    Contract Health shape: { service, version, erpReachable }. No auth
    (contract security: []). Always HTTP 200 -- a failed DB probe is reported as
    erpReachable:false, NOT a 5xx, so liveness stays distinct from ERP
    reachability. useReturnValue="true" -> RETURN "200".

    The DB reachability probe lives in DatabaseConnection (one responsibility);
    this .p only composes the 3-field body by hand via the JSON Object Model.
    SOL-119: ProbeReachable() now uses the bounded SOCKET probe of the broker
    (~ms..2s) rather than a full DB CONNECT, so /health stays fast while the
    ERP bounces; erpReachable therefore means "the broker answers", not "a
    DB-level login succeeded".
  ----------------------------------------------------------------------*/

BLOCK-LEVEL ON ERROR UNDO, THROW.

USING Progress.Json.ObjectModel.JsonObject.
USING ClearVue.Connector.Config.ConnectorConfig.
USING ClearVue.Connector.Data.DatabaseConnection.

DEFINE OUTPUT PARAMETER responseBody AS LONGCHAR NO-UNDO.

DEFINE VARIABLE oConfig AS ConnectorConfig    NO-UNDO.
DEFINE VARIABLE oDb     AS DatabaseConnection NO-UNDO.
DEFINE VARIABLE oJson   AS JsonObject         NO-UNDO.
DEFINE VARIABLE lReach  AS LOGICAL            NO-UNDO.

oConfig = NEW ConnectorConfig().
oDb     = NEW DatabaseConnection(oConfig).

/* lightweight, non-throwing reachability probe */
lReach = oDb:ProbeReachable() NO-ERROR.

oJson = NEW JsonObject().
oJson:Add("service":U,      "clearvue-openedge-connector":U).
oJson:Add("version":U,      "1.0.0":U).
oJson:Add("erpReachable":U, lReach).
oJson:Write(OUTPUT responseBody).

RETURN "200":U.

CATCH oErr AS Progress.Lang.Error:
    /* never fail health on an unexpected error; report minimal liveness */
    oJson = NEW JsonObject().
    oJson:Add("service":U,      "clearvue-openedge-connector":U).
    oJson:Add("version":U,      "1.0.0":U).
    oJson:Add("erpReachable":U, FALSE).
    oJson:Write(OUTPUT responseBody).
    RETURN "200":U.
END CATCH.
