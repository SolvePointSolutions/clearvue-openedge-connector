/*------------------------------------------------------------------------
    File        : ErrorClassifier.cls
    Package     : ClearVue.Connector.Web
    Purpose     : SOL-119 -- classify a raw Progress.Lang.Error into the
                  contract's connection-state (503, retryable) errors BEFORE
                  the generic catch-all can mislabel it INTERNAL/500.

    Why this exists: with the ERP DB stopped, faults can surface as raw
    Progress errors OUTSIDE DatabaseConnection:EnsureConnected() -- e.g.
    OE error 1006 ("Database <name> not connected.") raised while loading
    r-code that references the schema, or a mid-query connection loss.
    Without classification those funnel into the generic CATCH and go on the
    wire as INTERNAL / 500 / retryable:false with the RAW message (db name,
    class name, OE error number) leaked in `diagnostic`. This class is the
    single, table-driven "is this a known transient upstream state?" test.

    THE CLASSIFICATION TABLE (one place; inspectable; extend via env):

      OE error | meaning                                        | contract code
      ---------+------------------------------------------------+------------------
      1006     | Database <name> not connected (r-code load /   | ERP_DISCONNECTED
               | reference to a disconnected DB)                |
      1422     | client/server connection-loss family           | ERP_DISCONNECTED
      793      | lost connection to server (family)             | ERP_DISCONNECTED
      1423     | There is no server for database (broker down / | ERP_UNAVAILABLE
               | restarting)                                    |
      748      | server/system has no more resources (connect   | ERP_UNAVAILABLE
               | refused for resources)                         |
      1432     | cannot reach a server (network/firewall / no   | ERP_UNAVAILABLE
               | more servers). LIVE-PINNED 2026-07-02: downed  |
               | broker raised "Could not connect to server for |
               | database mfgpro, errno 0. (1432)"              |

      Both contract codes render category ERP_CONNECTIVITY, HTTP 503,
      retryable:true (see ConnectorError factories). Everything NOT in the
      table stays UNCLASSIFIED and the caller applies its own non-retryable
      fallback (ERP_QUERY_ERROR at the query seam, INTERNAL at the .p seam).

      NOTE: a DB LOGIN failure (bad -U/-P) surfaces through the CONNECT path
      inside EnsureConnected(), which already maps ANY in-budget connect
      failure to ERP_DISCONNECTED/503 -- so login failures are retryable-503
      by construction even without a pinned code here. When the live box
      surfaces a login/connect code NOT in the table, pin it via the env
      extension below (configuration, not a code fork), then fold it into
      this base table.

      ENV EXTENSION: CLEARVUE_CONNECTION_STATE_ERROR_CODES -- optional,
      comma-separated `oeErrNum=CONTRACT_CODE` pairs appended to the base
      table, e.g. "2624=ERP_UNAVAILABLE,562=ERP_DISCONNECTED". Lets a site
      pin its observed broker-restart / login-failure code without a rebuild.

    SANITIZATION CONTRACT (SOL-119): the ConnectorError this class returns
    carries ONLY stable, sanitized wire text (no db name, no class name, no
    OE error number). The full raw detail is preserved in
    ConnectorError:RawDetail, which is NEVER serialized -- the entry seam
    logs it server-side keyed by the correlationId (ConnectorLog).

    One responsibility: classify + sanitize raw errors. No DB, no HTTP.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Web.ErrorClassifier:

    /* Base pinned table: `oeErrNum=CONTRACT_CODE` pairs. Documented above --
       keep the comment table and this literal in lockstep. */
    DEFINE PRIVATE STATIC VARIABLE cBaseTable AS CHARACTER NO-UNDO INITIAL
        "1006=ERP_DISCONNECTED,1422=ERP_DISCONNECTED,793=ERP_DISCONNECTED,1423=ERP_UNAVAILABLE,748=ERP_UNAVAILABLE,1432=ERP_UNAVAILABLE":U.

    /* The effective table = base + optional site-pinned env extension. */
    METHOD PRIVATE STATIC CHARACTER EffectiveTable():
        DEFINE VARIABLE cExtra AS CHARACTER NO-UNDO.
        cExtra = OS-GETENV("CLEARVUE_CONNECTION_STATE_ERROR_CODES":U).
        IF cExtra = ? OR TRIM(cExtra) = "":U THEN
            RETURN cBaseTable.
        RETURN cBaseTable + ",":U + TRIM(cExtra).
    END METHOD.

    /* Look up the contract code ("ERP_DISCONNECTED"/"ERP_UNAVAILABLE") for an
       OE error number; "" when the number is not a known connection-state
       condition. Exact-entry match (never substring). */
    METHOD PUBLIC STATIC CHARACTER ContractCodeFor(INPUT piErrNum AS INTEGER):
        DEFINE VARIABLE cTable AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cEntry AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iIdx   AS INTEGER   NO-UNDO.

        IF piErrNum = 0 OR piErrNum = ? THEN
            RETURN "":U.

        cTable = EffectiveTable().
        DO iIdx = 1 TO NUM-ENTRIES(cTable):
            cEntry = TRIM(ENTRY(iIdx, cTable)).
            IF NUM-ENTRIES(cEntry, "=":U) = 2
               AND TRIM(ENTRY(1, cEntry, "=":U)) = STRING(piErrNum) THEN
                RETURN TRIM(ENTRY(2, cEntry, "=":U)).
        END.
        RETURN "":U.
    END METHOD.

    /* TRUE when the OE error number is a known connection-state condition.
       DatabaseConnection:IsDisconnectError delegates here so the table can
       never fork between the pre-flight and the raw-fault paths. */
    METHOD PUBLIC STATIC LOGICAL IsConnectionStateError(INPUT piErrNum AS INTEGER):
        RETURN ContractCodeFor(piErrNum) <> "":U.
    END METHOD.

    /* THE classification step (runs before any generic catch-all): walk ALL
       messages on the raw error (a wrapped/multi-message error may carry the
       connection-state number after message 1); first table hit wins.

       Returns a fully-sanitized retryable ConnectorError (RawDetail set for
       server-side logging), or the typed unknown when the fault is NOT a
       known connection-state condition -- the caller then applies its own
       non-retryable fallback. */
    METHOD PUBLIC STATIC ClearVue.Connector.Web.ConnectorError ClassifyConnectionState(
            INPUT poError AS Progress.Lang.Error):
        DEFINE VARIABLE iMsg        AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cCode       AS CHARACTER NO-UNDO.
        DEFINE VARIABLE oClassified AS ClearVue.Connector.Web.ConnectorError NO-UNDO.

        IF NOT VALID-OBJECT(poError) THEN
            RETURN oClassified.   /* typed unknown -- nothing to classify */

        DO iMsg = 1 TO poError:NumMessages:
            cCode = ContractCodeFor(poError:GetMessageNum(iMsg)).
            IF cCode = "":U THEN
                NEXT.

            /* Sanitized wire diagnostic ONLY -- a stable reason with no db
               name, no class name, no OE error number (SOL-119). */
            IF cCode = "ERP_UNAVAILABLE":U THEN
                oClassified = ClearVue.Connector.Web.ConnectorError:ErpUnavailable(
                    "upstream ERP is temporarily unavailable; retry shortly":U).
            ELSE
                oClassified = ClearVue.Connector.Web.ConnectorError:ErpDisconnected(
                    "upstream ERP connection is temporarily unavailable; retry shortly":U).

            /* full raw detail survives server-side, keyed by correlationId */
            oClassified:RawDetail = RawDetailOf(poError).
            RETURN oClassified.
        END.

        RETURN oClassified.   /* typed unknown -- caller picks its fallback */
    END METHOD.

    /* Compose the server-side-only raw detail: error type + every message
       with its OE number. This is what the connector LOG gets (keyed by the
       correlationId); it must NEVER be serialized to the wire. */
    METHOD PUBLIC STATIC CHARACTER RawDetailOf(INPUT poError AS Progress.Lang.Error):
        DEFINE VARIABLE iMsg    AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cDetail AS CHARACTER NO-UNDO.
        DEFINE VARIABLE oObj    AS Progress.Lang.Object NO-UNDO.
        DEFINE VARIABLE oClass  AS Progress.Lang.Class  NO-UNDO.

        IF NOT VALID-OBJECT(poError) THEN
            RETURN "":U.

        /* Progress.Lang.Error is an INTERFACE; GetClass() lives on
           Progress.Lang.Object -- CAST first so 11.6 resolves the member.
           And no method-return chaining on 11.6: assign each intermediate. */
        oObj    = CAST(poError, Progress.Lang.Object).
        oClass  = oObj:GetClass().
        cDetail = oClass:TypeName.

        DO iMsg = 1 TO poError:NumMessages:
            cDetail = cDetail
                + (IF iMsg = 1 THEN ": ":U ELSE "; ":U)
                + SUBSTITUTE("&1 (&2)":U,
                             poError:GetMessage(iMsg),
                             poError:GetMessageNum(iMsg)).
        END.
        RETURN cDetail.
    END METHOD.

END CLASS.
