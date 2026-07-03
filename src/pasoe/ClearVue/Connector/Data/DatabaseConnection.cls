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
      3. BOUNDED reconnect (SOL-119 rework -- see below), inside the
         reconnect ceiling (~6s).
      4. Clean stale state: DISCONNECT a half-dead handle before re-CONNECT.
      5. Outcome -> contract:
           reconnect ok                    -> proceed (bounce was invisible)
           broker probe never answers      -> THROW ConnectorError:ErpUnavailable
           broker answered, CONNECT failed -> THROW ConnectorError:ErpDisconnected
         (ERP_TIMEOUT is NO LONGER thrown from here -- it is reserved for a
          genuinely slow-but-alive upstream, i.e. a query-duration budget.)

    BOUNDED-CONNECT DESIGN (SOL-119 live-proof rework):
      The ABL database CONNECT statement is SYNCHRONOUS and, by default,
      makes ~50 OS-level tries before returning failure -- measured live at
      ~103 seconds against a downed broker (agent log, error 1432). A retry
      loop of blind CONNECTs therefore blew the ~6s budget by minutes. The
      budget can only be checked BETWEEN attempts; it cannot preempt a
      CONNECT in flight. Two verified mechanisms bound the wait:

      a) SOCKET PRE-PROBE. Before any CONNECT, probe the broker host:port
         with an ABL socket using `-clientConnectTimeout <ms>` (supported for
         non-SSL sockets since OpenEdge 11.3 -- Progress KB 000051142; NOTE:
         on OE 11 two connection attempts are made so the effective wait can
         be ~2x the value; OE 12 makes a single attempt). Probe fails ->
         classify immediately as ERP_UNAVAILABLE; NO CONNECT is issued.
      b) `-ct <n>` ON THE CONNECT. The DB CONNECT statement supports the
         Connection Retry Attempts parameter `-ct` (10.2B/11.x+ -- Progress
         KB "How to reduce the time for a CONNECT statement to return...").
         Default is ~50 tries; we append `-ct 1` (config) unless the
         operator's params/.pf already carry -ct, so one CONNECT costs one
         OS-level try (~2s observed live), not 50.

      ATTEMPT SHAPE: up to ReconnectMaxAttempts bounded PROBES (with backoff,
      ceiling-checked between attempts), but at most ONE actual CONNECT --
      issued only after a successful probe (or when the endpoint cannot be
      derived for probing). There is NO retry loop of blind CONNECTs.

      HONEST WORST CASE (documented in resilience-and-errors.md): a broker
      that ACCEPTS the TCP handshake but hangs the DB-level connect (e.g.
      mid-proshut) passes the probe, and the single `-ct`-bounded CONNECT can
      still block for one OS connect cycle -- bounded in tries, not in
      wall-clock. That is the residual corner; everything else lands near
      the budget.

    EnsureConnected() is the ONLY entry point every query calls before touching
    the DB. Keeping it here means every handler inherits identical resilience.
    It handles connect-from-scratch: the DB does NOT need to be (and should
    not be) in the PASOE agent startup parameters -- see deploy-and-run
    (agent-startup-params note; a DB down at agent boot must not wedge the
    agent, observed live as MSAS boot failure 5479 / status -1005).

    DISCONNECT-DETECTION NOTE:
      Reconnect must trigger only on a genuine client/server disconnect, never
      on an unrelated app error. The signals we trap:
        - CONNECTED(logicalDb) = FALSE  (authoritative pre-flight test)
        - raw OE connection-state errors via the ErrorClassifier table
          (SOL-119: the single classification table; 1432 "Could not connect
          to server for database <name>" is live-pinned from the 2026-07-02
          fault injection; extendable per site via
          CLEARVUE_CONNECTION_STATE_ERROR_CODES).

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

    /* Called once at session-activate (see SessionActivate.p) to make
       the connection persistent for the agent session. Safe to call when
       already connected (no-op). Swallows failure here -- the per-request
       EnsureConnected() is the authoritative gate and will surface a
       structured error to the caller. The CONNECT is `-ct`-bounded, so a
       DB that is down at activate time costs seconds, not minutes. */
    METHOD PUBLIC VOID ConnectAtActivate():
        IF NOT CONNECTED(oConfig:LogicalDbName) THEN
            TryConnect().
        RETURN.
    END METHOD.

    /* THE pre-flight gate. Call before every query. Returns normally when the
       logical DB is connected (reconnecting first if needed); THROWs a
       ConnectorError when it cannot reconnect inside the budget.

       Flow (SOL-119 bounded design -- see class header):
         probe(bounded) fail -> backoff -> probe ... -> ERP_UNAVAILABLE
         probe ok -> ONE `-ct`-bounded CONNECT -> ok | ERP_DISCONNECTED */
    METHOD PUBLIC VOID EnsureConnected():
        DEFINE VARIABLE iAttempt      AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iStartMs      AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iElapsedMs    AS INTEGER   NO-UNDO.
        DEFINE VARIABLE lConnected    AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE lProbeable    AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE lConnectTried AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE cHost         AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cService      AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cLastDiag     AS CHARACTER NO-UNDO.
        DEFINE VARIABLE oFail         AS ConnectorError NO-UNDO.

        IF CONNECTED(oConfig:LogicalDbName) THEN
            RETURN.   /* fast path: healthy persistent connection */

        iStartMs   = ETIME.
        lProbeable = ResolveBrokerEndpoint(OUTPUT cHost, OUTPUT cService).

        AttemptLoop:
        DO iAttempt = 1 TO oConfig:ReconnectMaxAttempts:

            /* ceiling guard between (bounded) attempts */
            iElapsedMs = ETIME - iStartMs.
            IF iElapsedMs >= oConfig:ReconnectCeilingMs THEN
                LEAVE AttemptLoop.

            IF lProbeable THEN
            DO:
                IF NOT ProbeBroker(cHost, cService, oConfig:ProbeTimeoutMs,
                                   OUTPUT cLastDiag) THEN
                DO:
                    /* broker did not answer inside the probe timeout --
                       do NOT issue a blind CONNECT; backoff and re-probe */
                    IF iAttempt < oConfig:ReconnectMaxAttempts THEN
                        PAUSE oConfig:ReconnectBackoffMs / 1000.0 NO-MESSAGE.
                    NEXT AttemptLoop.
                END.
            END.

            /* broker answered (or endpoint not derivable for probing) ->
               exactly ONE `-ct`-bounded CONNECT; never a blind-CONNECT loop */
            CleanStaleState().
            lConnectTried = TRUE.
            lConnected    = TryConnect(OUTPUT cLastDiag).
            IF lConnected THEN
                RETURN.   /* bounce healed -- invisible to the caller */
            LEAVE AttemptLoop.
        END.

        /* SOL-119 sanitization: wire diagnostics are stable reasons with NO
           db name / host / OE code; topology detail goes to RawDetail
           (server-side log only, keyed by correlationId). */
        iElapsedMs = ETIME - iStartMs.
        IF lConnectTried THEN
        DO:
            /* broker answered but the DB-level connect failed: mid-shutdown
               broker, refused login (bad/changed credentials), etc. */
            oFail = ConnectorError:ErpDisconnected(
                "upstream ERP connection could not be re-established; retry shortly":U).
            oFail:RawDetail = SUBSTITUTE(
                "reconnect to &1 failed (&2); &3; elapsed &4 ms":U,
                oConfig:LogicalDbName,
                (IF lProbeable THEN "after successful broker probe":U
                 ELSE "no broker endpoint derivable for probe":U),
                cLastDiag, iElapsedMs).
        END.
        ELSE
        DO:
            /* broker never answered a bounded probe -> we KNOW the upstream
               is unreachable (down/mid-restart/blocked) -- ERP_UNAVAILABLE,
               not the generic time-budget ERP_TIMEOUT */
            oFail = ConnectorError:ErpUnavailable(
                "upstream ERP is unreachable; retry shortly":U).
            oFail:RawDetail = SUBSTITUTE(
                "broker &1:&2 for &3 did not answer &4 bounded probe(s) (&5 ms each); elapsed &6 ms; &7":U,
                cHost, cService, oConfig:LogicalDbName,
                iAttempt - 1, oConfig:ProbeTimeoutMs, iElapsedMs, cLastDiag).
        END.
        UNDO, THROW oFail.
    END METHOD.

    /* If a half-dead handle lingers, drop it before re-CONNECT. */
    METHOD PRIVATE VOID CleanStaleState():
        IF CONNECTED(oConfig:LogicalDbName) THEN
            DISCONNECT VALUE(oConfig:LogicalDbName) NO-ERROR.
        RETURN.
    END METHOD.

    /* Attempt one CONNECT, bounded by `-ct` (appended unless the operator's
       params/.pf already set it -- reuse, don't override). Returns TRUE on
       success; FALSE plus a raw diagnostic (for RawDetail/log only). */
    METHOD PRIVATE LOGICAL TryConnect(OUTPUT pcDiagnostic AS CHARACTER):
        DEFINE VARIABLE iErr    AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cParams AS CHARACTER NO-UNDO.

        IF oConfig:ConnectParams = ? OR oConfig:ConnectParams = "":U THEN
            UNDO, THROW ConnectorError:Internal(
                "DB connect parameters are not configured (CLEARVUE_DB_CONNECT_PARAMS).":U).

        cParams = oConfig:ConnectParams.
        /* bound the synchronous CONNECT: default is ~50 OS-level tries
           (~103s observed live against a downed broker); -ct <n> caps it.
           Checked against the EFFECTIVE params (inline + .pf contents) so a
           .pf-supplied -ct is respected, not duplicated. */
        IF NOT HasParameter(EffectiveParamsText(), "-ct":U) THEN
            cParams = cParams + " -ct ":U + STRING(oConfig:ConnectRetryTries).

        CONNECT VALUE(cParams) NO-ERROR.

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

    /* Bounded TCP probe of the broker host:port. TRUE = the port completed a
       TCP connect inside the timeout. Uses the ABL socket CONNECT option
       -clientConnectTimeout (ms; non-SSL support since OE 11.3, KB 000051142;
       on OE 11 the effective wait can be ~2x the value -- two attempts --
       fixed to a single attempt on OE 12).
       NOTE: a TRUE probe only proves the port answers -- a broker mid-
       shutdown can accept TCP and still hang the DB-level connect; that is
       why the follow-up CONNECT is additionally `-ct`-bounded. */
    METHOD PRIVATE LOGICAL ProbeBroker(INPUT  pcHost      AS CHARACTER,
                                       INPUT  pcService   AS CHARACTER,
                                       INPUT  piTimeoutMs AS INTEGER,
                                       OUTPUT pcDiagnostic AS CHARACTER):
        DEFINE VARIABLE hSocket AS HANDLE  NO-UNDO.
        DEFINE VARIABLE lOk     AS LOGICAL NO-UNDO.

        CREATE SOCKET hSocket.
        lOk = hSocket:CONNECT(SUBSTITUTE("-H &1 -S &2 -clientConnectTimeout &3":U,
                                         pcHost, pcService, piTimeoutMs)) NO-ERROR.
        IF lOk THEN
            lOk = hSocket:CONNECTED().

        IF NOT lOk THEN
            pcDiagnostic = SUBSTITUTE(
                "broker probe &1:&2 did not answer within &3 ms":U,
                pcHost, pcService, piTimeoutMs).
        RETURN lOk.

        FINALLY:
            IF VALID-HANDLE(hSocket) THEN
            DO:
                hSocket:DISCONNECT() NO-ERROR.
                DELETE OBJECT hSocket NO-ERROR.
            END.
        END FINALLY.
    END METHOD.

    /* Derive the broker endpoint (-H host, -S service) for the probe from
       the CONFIGURED connect params -- inline tokens plus the contents of a
       referenced .pf -- reusing the existing configuration rather than
       duplicating host/port in a second setting. FALSE when not derivable
       (the caller then skips the probe and relies on the -ct bound alone). */
    METHOD PRIVATE LOGICAL ResolveBrokerEndpoint(OUTPUT pcHost    AS CHARACTER,
                                                 OUTPUT pcService AS CHARACTER):
        RETURN ExtractBrokerEndpoint(EffectiveParamsText(),
                                     OUTPUT pcHost, OUTPUT pcService).
    END METHOD.

    /* The configured params, flattened: the inline CLEARVUE_DB_CONNECT_PARAMS
       string plus the (comment-stripped) contents of each -pf file it
       references. Nested -pf inside a .pf is not chased (keep .pf flat). */
    METHOD PRIVATE CHARACTER EffectiveParamsText():
        DEFINE VARIABLE cInline AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cAll    AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cTok    AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iIdx    AS INTEGER   NO-UNDO.
        DEFINE VARIABLE lNextIsPf AS LOGICAL NO-UNDO.

        cInline = (IF oConfig:ConnectParams = ? THEN "":U ELSE oConfig:ConnectParams).
        cAll    = cInline.

        cInline = REPLACE(REPLACE(cInline, CHR(9), " ":U), CHR(10), " ":U).
        DO iIdx = 1 TO NUM-ENTRIES(cInline, " ":U):
            cTok = TRIM(ENTRY(iIdx, cInline, " ":U)).
            IF cTok = "":U THEN NEXT.
            IF lNextIsPf THEN
            DO:
                cAll = cAll + " ":U + ReadParamFileText(cTok).
                lNextIsPf = FALSE.
                NEXT.
            END.
            IF cTok = "-pf":U THEN
                lNextIsPf = TRUE.
        END.
        RETURN cAll.
    END METHOD.

    /* Read a .pf and return its content flattened to one space-separated
       params line, with #-comments stripped. "" when unreadable/absent. */
    METHOD PRIVATE STATIC CHARACTER ReadParamFileText(INPUT pcFile AS CHARACTER):
        DEFINE VARIABLE lcRaw AS LONGCHAR NO-UNDO.

        FILE-INFO:FILE-NAME = pcFile.
        IF FILE-INFO:FULL-PATHNAME = ? THEN
            RETURN "":U.

        COPY-LOB FROM FILE pcFile TO lcRaw NO-ERROR.
        IF ERROR-STATUS:ERROR OR lcRaw = ? THEN
            RETURN "":U.

        RETURN NormalizeParamFileText(STRING(lcRaw)).
    END METHOD.

    /* Flatten .pf text: normalize newlines, strip #-comments per line,
       join to one space-separated params string. PUBLIC STATIC + pure so
       ABLUnit can cover it without a DB or filesystem. */
    METHOD PUBLIC STATIC CHARACTER NormalizeParamFileText(INPUT pcText AS CHARACTER):
        DEFINE VARIABLE cText AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cLine AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cOut  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iIdx  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iHash AS INTEGER   NO-UNDO.

        IF pcText = ? THEN RETURN "":U.

        cText = REPLACE(pcText, CHR(13) + CHR(10), CHR(10)).
        cText = REPLACE(cText, CHR(13), CHR(10)).
        DO iIdx = 1 TO NUM-ENTRIES(cText, CHR(10)):
            cLine = ENTRY(iIdx, cText, CHR(10)).
            iHash = INDEX(cLine, "#":U).
            IF iHash > 0 THEN
                cLine = SUBSTRING(cLine, 1, iHash - 1).
            cOut = cOut + " ":U + cLine.
        END.
        RETURN TRIM(cOut).
    END METHOD.

    /* Parse -H <host> and -S <service/port> out of a flattened params
       string. PUBLIC STATIC + pure for ABLUnit. Exact-token match, case-
       sensitive (OpenEdge startup parameters are case-sensitive). */
    METHOD PUBLIC STATIC LOGICAL ExtractBrokerEndpoint(INPUT  pcParamsText AS CHARACTER,
                                                       OUTPUT pcHost       AS CHARACTER,
                                                       OUTPUT pcService    AS CHARACTER):
        DEFINE VARIABLE cText AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cTok  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iIdx  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cWant AS CHARACTER NO-UNDO.

        ASSIGN pcHost = "":U  pcService = "":U.
        IF pcParamsText = ? THEN RETURN FALSE.

        cText = REPLACE(REPLACE(pcParamsText, CHR(9), " ":U), CHR(10), " ":U).
        DO iIdx = 1 TO NUM-ENTRIES(cText, " ":U):
            cTok = TRIM(ENTRY(iIdx, cText, " ":U)).
            IF cTok = "":U THEN NEXT.
            IF cWant <> "":U THEN
            DO:
                IF cWant = "-H":U THEN pcHost    = cTok.
                ELSE                   pcService = cTok.
                cWant = "":U.
                NEXT.
            END.
            IF cTok = "-H":U OR cTok = "-S":U THEN
                cWant = cTok.
        END.
        RETURN pcHost <> "":U AND pcService <> "":U.
    END METHOD.

    /* TRUE when the exact parameter token is present in a flattened params
       string (exact token -- "-ct" never matches "-ctxyz"). PUBLIC STATIC +
       pure for ABLUnit. Case-sensitive like OpenEdge parameters. */
    METHOD PUBLIC STATIC LOGICAL HasParameter(INPUT pcParamsText AS CHARACTER,
                                              INPUT pcParam      AS CHARACTER):
        DEFINE VARIABLE cText AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iIdx  AS INTEGER   NO-UNDO.

        IF pcParamsText = ? THEN RETURN FALSE.
        cText = REPLACE(REPLACE(pcParamsText, CHR(9), " ":U), CHR(10), " ":U).
        DO iIdx = 1 TO NUM-ENTRIES(cText, " ":U):
            IF TRIM(ENTRY(iIdx, cText, " ":U)) = pcParam THEN
                RETURN TRUE.
        END.
        RETURN FALSE.
    END METHOD.

    /* Classify an OE error number as a client/server disconnect so a
       mid-query failure can be retried-once as a reconnect (vs a real app
       error which must propagate).

       SOL-119: delegates to the SINGLE table in ErrorClassifier (which also
       covers 1006 "Database not connected" and the env-pinned site codes) so
       the pre-flight test and the raw-fault classification can never drift.
       Kept as a named seam for callers/tests. */
    METHOD PUBLIC STATIC LOGICAL IsDisconnectError(INPUT piErrNum AS INTEGER):
        RETURN ClearVue.Connector.Web.ErrorClassifier:IsConnectionStateError(piErrNum).
    END METHOD.

    /* Lightweight probe for /health -- never throws; just reports
       reachability. SOL-119 rework: prefer the bounded SOCKET probe (~ms to
       ProbeTimeoutMs) over a full CONNECT, so /health stays cheap and fast
       while the ERP bounces. Falls back to one -ct-bounded CONNECT when the
       endpoint is not derivable. NOTE: `erpReachable` therefore means "the
       broker answers" -- it does not prove a DB-level login. */
    METHOD PUBLIC LOGICAL ProbeReachable():
        DEFINE VARIABLE cHost    AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cService AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cIgnored AS CHARACTER NO-UNDO.

        IF CONNECTED(oConfig:LogicalDbName) THEN
            RETURN TRUE.
        IF ResolveBrokerEndpoint(OUTPUT cHost, OUTPUT cService) THEN
            RETURN ProbeBroker(cHost, cService, oConfig:ProbeTimeoutMs,
                               OUTPUT cIgnored).
        RETURN TryConnect(OUTPUT cIgnored).
    END METHOD.

END CLASS.
