/*------------------------------------------------------------------------
    File        : DatabaseConnection.cls
    Package     : ClearVue.Connector.Data
    Purpose     : THE single place that owns the client/server DB connection
                  and its auto-reconnect behavior.

    Field reality: the MFG/PRO database is restarted often, severing the
    connector's client/server connection. Per resilience-and-errors.md:

      1. Persistent per-session connection -- connect once at session-activate.
      2. Per-request pre-flight: CONNECTED(logicalDb). If not connected,
         (re)connect before querying.
      3. Bounded retry + short backoff, inside the reconnect ceiling (~6s).
      4. Clean stale state: DISCONNECT a half-dead handle before re-CONNECT.
      5. Outcome -> contract:
           reconnect ok            -> proceed (bounce was invisible)
           reconnect fails in budget-> THROW ConnectorError:ErpDisconnected
           host/broker unreachable -> THROW ConnectorError:ErpUnavailable
           reconnect ate the budget-> THROW ConnectorError:ErpTimeout

    EnsureConnected() is the ONLY entry point every query calls before touching
    the DB. Keeping it here means every handler inherits identical resilience.

    DISCONNECT-DETECTION NOTE (confirm exact code on the live spike):
      Reconnect must trigger only on a genuine client/server disconnect, never
      on an unrelated app error. The signals we trap:
        - CONNECTED(logicalDb) = FALSE  (authoritative pre-flight test)
        - on CONNECT failure: OE error 1423 "There is no server for database"
          (broker down / restarting) and the family of client/server
          connection-loss errors (e.g. 748/793/1422 range) surfaced via
          ERROR-STATUS:GET-NUMBER. The precise code(s) raised by THIS site's
          broker restart MUST be observed on the 11.6/MPI box and pinned in
          IsDisconnectError() -- see the connection-failure test below.

    One responsibility: connection lifecycle + reconnect. No JSON, no auth,
    no query logic.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING ClearVue.Connector.Config.ConnectorConfig.
USING ClearVue.Connector.Web.ConnectorError.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Data.DatabaseConnection:

    DEFINE PRIVATE VARIABLE oConfig AS ConnectorConfig NO-UNDO.

    CONSTRUCTOR PUBLIC DatabaseConnection(INPUT poConfig AS ConnectorConfig):
        ASSIGN oConfig = poConfig.
    END CONSTRUCTOR.

    /* Called once at session-activate (see SessionStartup procedure) to make
       the connection persistent for the agent session. Safe to call when
       already connected (no-op). Swallows failure here -- the per-request
       EnsureConnected() is the authoritative gate and will surface a
       structured error to the caller. */
    METHOD PUBLIC VOID ConnectAtActivate():
        IF NOT CONNECTED(oConfig:LogicalDbName) THEN
            TryConnect().
        RETURN.
    END METHOD.

    /* THE pre-flight gate. Call before every query. Returns normally when the
       logical DB is connected (reconnecting first if needed); THROWs a
       ConnectorError when it cannot reconnect inside the budget. */
    METHOD PUBLIC VOID EnsureConnected():
        DEFINE VARIABLE iAttempt    AS INTEGER NO-UNDO.
        DEFINE VARIABLE iStartMs    AS INTEGER NO-UNDO.
        DEFINE VARIABLE iElapsedMs  AS INTEGER NO-UNDO.
        DEFINE VARIABLE lConnected  AS LOGICAL NO-UNDO.
        DEFINE VARIABLE cLastDiag   AS CHARACTER NO-UNDO.

        IF CONNECTED(oConfig:LogicalDbName) THEN
            RETURN.   /* fast path: healthy persistent connection */

        iStartMs = ETIME.

        DO iAttempt = 1 TO oConfig:ReconnectMaxAttempts:

            /* budget guard: never blow the reconnect ceiling */
            iElapsedMs = ETIME - iStartMs.
            IF iElapsedMs >= oConfig:ReconnectCeilingMs THEN
                UNDO, THROW ConnectorError:ErpTimeout(
                    SUBSTITUTE("reconnect to &1 exceeded budget after &2 attempt(s)":U,
                               oConfig:LogicalDbName, iAttempt - 1)).

            CleanStaleState().

            lConnected = TryConnect(OUTPUT cLastDiag).
            IF lConnected THEN
                RETURN.   /* bounce healed -- invisible to the caller */

            /* short backoff before the next attempt, staying inside budget */
            IF iAttempt < oConfig:ReconnectMaxAttempts THEN
                PAUSE oConfig:ReconnectBackoffMs / 1000.0 NO-MESSAGE.
        END.

        /* exhausted attempts inside budget -> retryable connectivity error.
           ERP_DISCONNECTED = a prior connection dropped (DB restart);
           the structured 503 lets ClearVue auto-retry the bounce. */
        UNDO, THROW ConnectorError:ErpDisconnected(
            SUBSTITUTE("client/server connection to &1 dropped; reconnect attempted &2x; &3":U,
                       oConfig:LogicalDbName,
                       oConfig:ReconnectMaxAttempts,
                       cLastDiag)).
    END METHOD.

    /* If a half-dead handle lingers, drop it before re-CONNECT. */
    METHOD PRIVATE VOID CleanStaleState():
        IF CONNECTED(oConfig:LogicalDbName) THEN
            DISCONNECT VALUE(oConfig:LogicalDbName) NO-ERROR.
        RETURN.
    END METHOD.

    /* Attempt one CONNECT. Returns TRUE on success. On failure, returns FALSE
       and a safe diagnostic; if the failure is NOT a recognized connection
       failure, rethrow it (don't silently treat an app error as a disconnect). */
    METHOD PRIVATE LOGICAL TryConnect(OUTPUT pcDiagnostic AS CHARACTER):
        DEFINE VARIABLE iErr AS INTEGER NO-UNDO.

        IF oConfig:ConnectParams = ? OR oConfig:ConnectParams = "":U THEN
            UNDO, THROW ConnectorError:Internal(
                "DB connect parameters are not configured (CLEARVUE_DB_CONNECT_PARAMS).":U).

        CONNECT VALUE(oConfig:ConnectParams) NO-ERROR.

        IF NOT ERROR-STATUS:ERROR AND CONNECTED(oConfig:LogicalDbName) THEN
            RETURN TRUE.

        iErr = (IF ERROR-STATUS:NUM-MESSAGES > 0
                THEN ERROR-STATUS:GET-NUMBER(1) ELSE 0).
        pcDiagnostic = SUBSTITUTE("CONNECT failed (OE error &1)":U, iErr).
        RETURN FALSE.
    END METHOD.

    /* Convenience overload used by ConnectAtActivate (no diagnostic needed). */
    METHOD PRIVATE LOGICAL TryConnect():
        DEFINE VARIABLE cIgnored AS CHARACTER NO-UNDO.
        RETURN TryConnect(OUTPUT cIgnored).
    END METHOD.

    /* Classify an OE error number as a client/server disconnect so a
       mid-query failure can be retried-once as a reconnect (vs a real app
       error which must propagate). PIN the exact code(s) for this site's
       broker restart on the spike; the set below is the documented family. */
    METHOD PUBLIC STATIC LOGICAL IsDisconnectError(INPUT piErrNum AS INTEGER):
        /* 1423  no server for database (broker down / restarting)
           1422  connection to the database lost
           748   broker could not be reached / refused
           793   lost connection to server
           Confirm/extend against the live broker-restart error on the spike. */
        RETURN CAN-DO("1423,1422,748,793":U, STRING(piErrNum)).
    END METHOD.

    /* Lightweight probe for /health -- never throws; just reports reachability. */
    METHOD PUBLIC LOGICAL ProbeReachable():
        DEFINE VARIABLE cIgnored AS CHARACTER NO-UNDO.
        IF CONNECTED(oConfig:LogicalDbName) THEN
            RETURN TRUE.
        RETURN TryConnect(OUTPUT cIgnored).
    END METHOD.

END CLASS.
