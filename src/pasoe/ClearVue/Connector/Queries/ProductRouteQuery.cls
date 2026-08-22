/* SPDX-License-Identifier: Apache-2.0 */
/*------------------------------------------------------------------------
    File        : ProductRouteQuery.cls
    Package     : ClearVue.Connector.Queries
                  (NOT "Query" -- QUERY is a reserved ABL keyword; a reserved
                  word as a package segment makes the type unresolvable on 11.6.
                  Same rule ProductStructureQuery documents.)
    Purpose     : Routing (operation steps) for a part at a site -> rows shaped
                  to the contract RouteStep[].

    Ports the LOGIC of the legacy xx-rorp.p (standalone route) and the route
    leg of xx-rprdcvr.p (cover-sheet route). Reference only; names not carried
    forward -- the connector emits the ClearVue-canonical field names directly
    (OperationNumber, StandardOperation, WorkCenterId, Machine, SetupHours,
    RunHoursPerPiece, YieldPercent, ...) so stock output == SaaS ErpRouteStep ==
    identity, no mapping layer (Rod, 2026-07-05).

    ONE ENGINE, TWO SHAPES. This class always populates the FULL route row --
    every standard field PLUS the two cover-sheet-only fields (PiecesPerHour,
    WorkCenterDescription) -- and always harvests routing comments. The two
    consumers pick what they render:
      - /product-route (ProductRouteJsonComposer): standard fields only; the
        two cover-sheet-only fields and the comments are ignored (contract
        RouteStep marks PiecesPerHour/WorkCenterDescription "cover-sheet only").
      - /product-cover-sheet (ProductCoverSheetQuery reuses THIS class): renders
        the full route row + the harvested Comments[].
    Sharing one engine keeps the route resolution identical across both
    endpoints instead of the two divergent legacy loops.

    Cleaned up vs legacy (documented divergences -- see docs + commit body):
      - Domain comes from ConnectorConfig (legacy hard-coded "MPI").
      - RunHoursPerPiece = ro_run (run hours per piece). The cover-sheet legacy
        computed runtime = open_ref * ro_run, and open_ref was never set, so it
        was ALWAYS 0 -- a latent legacy bug. We emit ro_run directly, matching
        the standalone route (xx-rorp.p) and the field's meaning.
      - The cover-sheet route now carries the FULL standard field set (Machine,
        dates, SetupHours, Wait, Move, YieldPercent, Tool), not the sparse
        OP/STDOP/Desc/WorkCenter/Pcs-Hr set the legacy tt-rt populated.
      - Routing resolution: ptp_det(domain, part, site).ptp_routing; when that
        is blank, OR when the part has no ptp_det for the site, fall back to the
        part itself as the routing code (many MFG/PRO shops route-code == part).
        The legacy site="1"-only fallback is NOT carried forward -- it was an
        MPI-specific quirk and `facility` is now generic.
      - Read-only NO-LOCK throughout. DB resilience delegated to
        DatabaseConnection:EnsureConnected(); SOL-119 classification on faults.

    EXISTENCE vs EMPTY (mirrors the structure SOL-58 ruling): "does the part
    exist?" is a REAL pt_mstr lookup, exposed via PartExists(). A part absent
    from pt_mstr -> caller returns 404. A part that exists but has no routing
    steps -> PartExists() TRUE, 0 rows -> caller returns 200 with an EMPTY
    array (NOT a 404, NOT a synthetic "Routing not found" row like the legacy).

    The temp-tables are the connector-internal shape (canonical names).
    ProductRouteJsonComposer / ProductCoverSheetJsonComposer serialize them via
    the JSON Object Model -- this class does NOT serialize.

    One responsibility: produce route rows (+ comments). No JSON, no auth, no HTTP.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING ClearVue.Connector.Config.ConnectorConfig.
USING ClearVue.Connector.Data.DatabaseConnection.
USING ClearVue.Connector.Web.ConnectorError.
USING ClearVue.Connector.Web.ErrorClassifier.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Queries.ProductRouteQuery:

    DEFINE PRIVATE VARIABLE oConfig AS ConnectorConfig    NO-UNDO.
    DEFINE PRIVATE VARIABLE oDb     AS DatabaseConnection NO-UNDO.

    /* Connector-internal result shape, canonical field names already applied.
       PRIVATE per the 11.6 rule (a TEMP-TABLE class member may only be PRIVATE/
       PROTECTED); external access is via GetResultsHandle(). Field scales match
       the contract wire-format standard (feasibility-11.6 §3): Setup/Wait/Move
       3dp, Runtime 9dp, YieldPercent 2dp. PiecesPerHour 4dp (derived 1/ro_run;
       tunable). */
    DEFINE PRIVATE TEMP-TABLE ttProductRoute NO-UNDO
        FIELD SeqNo                 AS INTEGER   /* preserve ro_op order */
        FIELD OperationNumber       AS CHARACTER
        FIELD StandardOperation     AS CHARACTER
        FIELD Description           AS CHARACTER
        FIELD WorkCenterId          AS CHARACTER
        FIELD Machine               AS CHARACTER
        FIELD StartDate             AS DATE
        FIELD EndDate               AS DATE
        FIELD SetupHours            AS DECIMAL DECIMALS 3
        FIELD RunHoursPerPiece      AS DECIMAL DECIMALS 9
        FIELD Wait                  AS DECIMAL DECIMALS 3
        FIELD Move                  AS DECIMAL DECIMALS 3
        FIELD YieldPercent          AS DECIMAL DECIMALS 2
        FIELD Tool                  AS CHARACTER
        FIELD PiecesPerHour         AS DECIMAL DECIMALS 4  /* cover-sheet only */
        FIELD WorkCenterDescription AS CHARACTER           /* cover-sheet only */
        INDEX idxSeq IS PRIMARY SeqNo.

    /* Routing comments (cmt_det), harvested for the cover sheet's Comments[].
       /product-route ignores this table. */
    DEFINE PRIVATE TEMP-TABLE ttRouteComment NO-UNDO
        FIELD SeqNo   AS INTEGER
        FIELD Comment AS CHARACTER
        INDEX idxSeq IS PRIMARY SeqNo.

    DEFINE PRIVATE VARIABLE cDomain    AS CHARACTER NO-UNDO.
    DEFINE PRIVATE VARIABLE iSeq       AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE iCmtSeq    AS INTEGER   NO-UNDO.
    DEFINE PRIVATE VARIABLE lPartFound AS LOGICAL   NO-UNDO.

    CONSTRUCTOR PUBLIC ProductRouteQuery(INPUT poConfig AS ConnectorConfig,
                                         INPUT poDb     AS DatabaseConnection):
        ASSIGN
            oConfig = poConfig
            oDb     = poDb.
    END CONSTRUCTOR.

    /* Route rows in ro_op (SeqNo) order, by HANDLE (same reason as structure --
       an instance temp-table can't be used in a static FOR EACH elsewhere). */
    METHOD PUBLIC HANDLE GetResultsHandle():
        RETURN TEMP-TABLE ttProductRoute:HANDLE.
    END METHOD.

    /* Harvested routing comments (for the cover sheet). */
    METHOD PUBLIC HANDLE GetCommentsHandle():
        RETURN TEMP-TABLE ttRouteComment:HANDLE.
    END METHOD.

    /* TRUE when the requested part exists in pt_mstr (set by Execute). Lets the
       caller distinguish 404 (part absent) from 200-empty (part present, no
       routing). */
    METHOD PUBLIC LOGICAL PartExists():
        RETURN lPartFound.
    END METHOD.

    /* Run the route lookup. Empties + repopulates both temp-tables. Returns the
       route-row count (0 = no routing steps). Check PartExists() for 404 vs
       200-empty. THROWs ConnectorError on connectivity/query failure. */
    METHOD PUBLIC INTEGER Execute(INPUT pcPart AS CHARACTER,
                                  INPUT pcSite AS CHARACTER):
        DEFINE VARIABLE oClassified AS ConnectorError NO-UNDO.
        DEFINE VARIABLE oFallback   AS ConnectorError NO-UNDO.

        EMPTY TEMP-TABLE ttProductRoute.
        EMPTY TEMP-TABLE ttRouteComment.
        ASSIGN
            iSeq       = 0
            iCmtSeq    = 0
            lPartFound = FALSE
            cDomain    = oConfig:ErpDomain.

        IF cDomain = "":U THEN
            UNDO, THROW ConnectorError:Internal(
                "ERP domain is not configured (CLEARVUE_ERP_DOMAIN).":U).

        /* pre-flight DB gate -- reconnects on a DB-restart drop or throws */
        oDb:EnsureConnected().

        BuildRoute(INPUT pcPart, INPUT pcSite).

        RETURN iSeq.

        /* connection lost mid-query -> retryable connectivity error */
        CATCH oConnErr AS ConnectorError:
            UNDO, THROW oConnErr.
        END CATCH.
        /* SOL-119: classify a known connection-state fault before the generic
           fallback; sanitized wire diagnostic, raw detail preserved server-side. */
        CATCH oErr AS Progress.Lang.Error:
            oClassified = ErrorClassifier:ClassifyConnectionState(oErr).
            IF VALID-OBJECT(oClassified) THEN
                UNDO, THROW oClassified.

            oFallback = ConnectorError:ErpQueryError(
                "route query failed unexpectedly":U).
            oFallback:RawDetail = ErrorClassifier:RawDetailOf(oErr).
            UNDO, THROW oFallback.
        END CATCH.
    END METHOD.

    /* Existence gate + routing-code resolution, then the ro_det step loop. */
    METHOD PRIVATE VOID BuildRoute(INPUT pcPart AS CHARACTER,
                                   INPUT pcSite AS CHARACTER):
        DEFINE VARIABLE cRouting AS CHARACTER NO-UNDO.
        DEFINE BUFFER bPt  FOR pt_mstr.
        DEFINE BUFFER bPtp FOR ptp_det.

        /* THE existence check: part master lookup. Absent => 404 (caller). */
        FIND FIRST bPt NO-LOCK
            WHERE bPt.pt_domain = cDomain
              AND bPt.pt_part   = pcPart NO-ERROR.
        IF NOT AVAILABLE bPt THEN
            RETURN.   /* lPartFound stays FALSE -> caller returns 404 */
        lPartFound = TRUE.

        /* resolve the routing code for this part+site: ptp_det.ptp_routing,
           falling back to the part itself when blank or when the site has no
           ptp_det row (route-code == part is common in MFG/PRO). */
        cRouting = pcPart.
        FIND FIRST bPtp NO-LOCK
            WHERE bPtp.ptp_domain = cDomain
              AND bPtp.ptp_part   = pcPart
              AND bPtp.ptp_site   = pcSite NO-ERROR.
        IF AVAILABLE bPtp AND bPtp.ptp_routing <> "":U THEN
            cRouting = bPtp.ptp_routing.

        BuildRouteSteps(INPUT cRouting).
        RETURN.
    END METHOD.

    /* Emit one row per effective ro_det operation, in ro_op order, enriched
       with work-center description and pieces-per-hour, harvesting each
       operation's comments. */
    METHOD PRIVATE VOID BuildRouteSteps(INPUT pcRouting AS CHARACTER):
        DEFINE BUFFER bRo FOR ro_det.
        DEFINE BUFFER bWc FOR wc_mstr.

        FOR EACH bRo NO-LOCK
            WHERE bRo.ro_domain  = cDomain
              AND bRo.ro_routing = pcRouting
            BY bRo.ro_op:

            /* Skip feature/option (configured-product / subcontract) routing
               rows; keep NORMAL operations. The rule -- including the unknown
               case and the SOL-174 history -- lives on
               RouteRules:IsNormalOperation(), a schema-free class so ABLUnit
               can pin it without a DB. Behaviour is unchanged from the inline
               guard this replaced. */
            IF NOT ClearVue.Connector.Queries.RouteRules:IsNormalOperation(bRo.ro_fsm_type) THEN
                NEXT.

            iSeq = iSeq + 1.
            CREATE ttProductRoute.
            ASSIGN
                ttProductRoute.SeqNo             = iSeq
                ttProductRoute.OperationNumber   = STRING(bRo.ro_op)
                ttProductRoute.StandardOperation = bRo.ro_std_op
                ttProductRoute.Description        = bRo.ro_desc
                ttProductRoute.WorkCenterId      = bRo.ro_wkctr
                ttProductRoute.Machine           = bRo.ro_mch
                ttProductRoute.StartDate         = bRo.ro_start
                ttProductRoute.EndDate           = bRo.ro_end
                ttProductRoute.SetupHours        = bRo.ro_setup
                ttProductRoute.RunHoursPerPiece  = bRo.ro_run
                ttProductRoute.Wait              = bRo.ro_wait
                ttProductRoute.Move              = bRo.ro_move
                ttProductRoute.YieldPercent      = bRo.ro_yield_pct
                ttProductRoute.Tool              = bRo.ro_tool
                /* pieces per hour = 1 / run-hours-per-piece (0 when run is 0) */
                ttProductRoute.PiecesPerHour     = (IF bRo.ro_run <> 0
                                                    THEN 1 / bRo.ro_run ELSE 0).

            /* work-center description (cover-sheet only field) */
            FIND FIRST bWc NO-LOCK
                WHERE bWc.wc_domain = cDomain
                  AND bWc.wc_wkctr  = bRo.ro_wkctr
                  AND bWc.wc_mch    = bRo.ro_mch NO-ERROR.
            IF AVAILABLE bWc THEN
                ttProductRoute.WorkCenterDescription = bWc.wc_desc.

            HarvestComments(INPUT bRo.ro_cmtindx).
        END.
        RETURN.
    END METHOD.

    /* Harvest an operation's comment lines (cmt_det) into ttRouteComment.
       No-op when the operation carries no comment index. */
    METHOD PRIVATE VOID HarvestComments(INPUT pdCmtIndx AS DECIMAL):
        DEFINE VARIABLE iLine AS INTEGER NO-UNDO.
        DEFINE BUFFER bCmt FOR cmt_det.

        IF pdCmtIndx = 0 OR pdCmtIndx = ? THEN
            RETURN.

        FIND FIRST bCmt NO-LOCK
            WHERE bCmt.cmt_domain = cDomain
              AND bCmt.cmt_indx   = pdCmtIndx NO-ERROR.
        IF NOT AVAILABLE bCmt THEN
            RETURN.

        DO iLine = 1 TO EXTENT(bCmt.cmt_cmmt):
            IF bCmt.cmt_cmmt[iLine] <> "":U THEN
            DO:
                iCmtSeq = iCmtSeq + 1.
                CREATE ttRouteComment.
                ASSIGN
                    ttRouteComment.SeqNo   = iCmtSeq
                    ttRouteComment.Comment = bCmt.cmt_cmmt[iLine].
            END.
        END.
        RETURN.
    END METHOD.

END CLASS.
