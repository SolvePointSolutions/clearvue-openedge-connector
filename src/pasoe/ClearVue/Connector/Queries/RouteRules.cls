/* SPDX-License-Identifier: Apache-2.0 */
/*------------------------------------------------------------------------
    File        : RouteRules.cls
    Package     : ClearVue.Connector.Queries
    Purpose     : PURE routing rules -- the decisions the route walk makes
                  about a ro_det row, lifted out of the walk itself.

    NO SCHEMA. This class deliberately declares no buffers and names no
    MFG/PRO table. ProductRouteQuery cannot compile without a connected
    schema (it buffers ro_det, pt_mstr, ptp_det, wc_mstr, cmt_det -- the
    compiler stops at "Unknown or ambiguous table pt_mstr (545)"), which
    would drag a DB requirement into the whole unit suite. Keeping the rules
    here means ABLUnit covers them on any OpenEdge install -- the same
    PUBLIC STATIC + pure seam DatabaseConnection uses for its param parsing.

    The route WALK stays DB-bound and remains a [LIVE-ONLY] smoke step
    (docs/deploy-and-run-11.6.md). What is unit-testable here is the rule,
    not the query.
  ----------------------------------------------------------------------*/

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Queries.RouteRules:

    /* TRUE when a ro_det row is a NORMAL routing operation -- i.e. NOT a
       feature/option, configured-product or subcontract row.

       BEHAVIOUR-PRESERVING. This is the rule the route walk has always
       applied, lifted out verbatim so a test can reach it. Every input
       below resolves exactly as it did inline. Do not "tidy" it without
       re-running the SOL-174 tests -- the whole point of extracting it was
       to make a change here visible.

         ro_fsm_type    normal?   note
         ------------   -------   ------------------------------------------
         ""             yes       what a real unpopulated MFG/PRO field holds
         " " / "   "    yes       blank after TRIM
         "S", "F", ...  no        a real FSM / subcontract type code
         "  S  "        no        TRIM must not launder a real code to blank
         ? (unknown)    no        see below

       UNKNOWN IS NOT NORMAL, and that is inherited behaviour, not a choice
       made here. ABL does not treat "?" as three-valued in this comparison:
       "? <> ''" evaluates to TRUE (unknown sorts below any value), so both
       the original guard and its successor took the skip branch on an
       unknown ro_fsm_type. Verified on the runtime, not assumed. An unknown
       row has therefore always been dropped from the route. Whether that is
       DESIRABLE is a separate question and an open one -- but changing it is
       a behaviour change and needs its own ticket, not a quiet edit here.

       ON SOL-174. That ticket recorded this guard as a live defect: the
       legacy xx-rorp.p form "ro_fsm_type <> ' '" was said to match nothing
       -- because Progress has no null and normal rows carry "" rather than a
       space -- and so to drop every normal operation silently. The premise
       does not hold. ABL character comparison IGNORES TRAILING BLANKS, so
       "" = " " is TRUE and "" <> " " is FALSE; the old guard kept normal
       rows exactly as this one does. Confirmed against the OpenEdge runtime
       across all six inputs above: old and new agree on every one, so the
       SOL-174 change was a no-op. Only COMPARE(a, "EQ", b, "RAW") would have
       distinguished "" from " ".

       Retained in the TRIM form regardless: it states the intent ("blank
       means normal") without depending on a padding rule the reader has to
       know. But it fixed nothing, and any routing shortfall still seen on
       real MPI has a cause that is still unfound. */
    METHOD PUBLIC STATIC LOGICAL IsNormalOperation(INPUT pcFsmType AS CHARACTER):
        /* unknown -> not normal, matching the inline guard this replaced */
        IF pcFsmType = ? THEN
            RETURN FALSE.
        RETURN TRIM(pcFsmType) = "":U.
    END METHOD.

END CLASS.
