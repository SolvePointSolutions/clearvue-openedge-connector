/*------------------------------------------------------------------------
    File        : SessionActivate.p
    Package     : ClearVue.Connector.Data (procedural by necessity)
    Purpose     : PASOE session-activate hook -- establish the PERSISTENT
                  per-session client/server DB connection once, so requests
                  reuse it (low latency) and only reconnect on a real drop.

    Wire-up: register this as the ABL "Session Activate" procedure for the
    PASOE ABL application, e.g. in openedge.properties:
        [<instance>.ROOT.APSV]
        srvrActivateProc=ClearVue/Connector/Data/SessionActivate.p
    (or via oeprop / the OE Explorer ABL-app session properties).

    It deliberately does NOT throw: a DB that is down at activate time must not
    wedge the agent -- the per-request DatabaseConnection:EnsureConnected() is
    the authoritative gate and will reconnect (or return a structured error).

    Also pins invariant numeric formatting for the session so a localized agent
    never emits "1,5" in JSON (belt-and-suspenders alongside JsonFormat).
  ----------------------------------------------------------------------*/

USING ClearVue.Connector.Config.ConnectorConfig.
USING ClearVue.Connector.Data.DatabaseConnection.

BLOCK-LEVEL ON ERROR UNDO, THROW.

DEFINE VARIABLE oConfig AS ConnectorConfig    NO-UNDO.
DEFINE VARIABLE oDb     AS DatabaseConnection NO-UNDO.

/* invariant numeric output for JSON numbers (defensive; see JsonFormat) */
SESSION:NUMERIC-FORMAT = "AMERICAN":U.

oConfig = NEW ConnectorConfig().
oDb     = NEW DatabaseConnection(oConfig).

/* best-effort persistent connect; never fatal at activate */
oDb:ConnectAtActivate() NO-ERROR.

FINALLY:
    DELETE OBJECT oDb     NO-ERROR.
    DELETE OBJECT oConfig NO-ERROR.
END FINALLY.
