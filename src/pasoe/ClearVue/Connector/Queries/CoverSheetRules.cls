/* SPDX-License-Identifier: Apache-2.0 */
/*------------------------------------------------------------------------
    File        : CoverSheetRules.cls
    Package     : ClearVue.Connector.Queries
    Purpose     : PURE cover-sheet header rules -- the decisions the header
                  build makes about values it has already read, lifted out of
                  the DB-bound query so a test can reach them.

    NO SCHEMA. Same seam, same reason as RouteRules: ProductCoverSheetQuery
    buffers pt_mstr, ptp_det, cp_mstr, cm_mstr and ad_mstr, so it cannot
    compile without a connected schema, and putting a rule there would drag a
    DB requirement into the whole unit suite. This class declares no buffers
    and names no MFG/PRO table, so ABLUnit covers it on any OpenEdge install.

    What is unit-testable here is the RULE. Which RECORD feeds it -- the
    cp_mstr row ResolveCustomer matches -- is decided by the DB-bound query
    and stays a [LIVE-ONLY] smoke step (test/smoke/route-coversheet-smoke.sh).
  ----------------------------------------------------------------------*/

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Queries.CoverSheetRules:

    /* The cover-sheet QtyPallet value (SOL-1736).

       Ports the legacy xx-rprdcvr.p rule, which is live legacy code:
         pallet_qty = STRING(ptp_ord_mult)                  -- item-site row
         ... then, on the FIRST cp_mstr whose customer matches a cm_mstr:
         IF pallet_qty = "0" THEN pallet_qty = cp_comment.

         site record  ptp_ord_mult  customer matched  QtyPallet
         -----------  ------------  ----------------  ------------------------
         yes          non-zero      either            STRING(ptp_ord_mult)
         yes          0             yes               cp_comment, VERBATIM
         yes          0             no                blank      (1b, below)
         no           --            either            blank      (inherited)

       pcCustomerComment MUST be the cp_comment of the same cp_mstr record the
       caller used for ShipTo / CustItem -- the matched one. The caller
       (ProductCoverSheetQuery:ResolveCustomer) guarantees that; this rule
       cannot, so it ignores the comment entirely unless plCustomerMatched.

       VERBATIM. cp_comment is free text. The legacy applied no TRIM and no
       numeric check, and neither does this: "SEE PKG SPEC" comes back as
       "SEE PKG SPEC", "  36" keeps its leading blanks, and "0" stays "0". A
       blank comment comes back blank, which the composer emits as JSON null.

       1b -- ord_mult 0 and NO matched customer. The legacy leaves the string
       "0" here. The connector returns blank (JSON null; ClearVue shows a dash),
       as it always has. RULED 2026-10-22 (SOL-1736 1b): blank stays, not the
       legacy "0". Do not change it to "0" without a new ruling.

       NO SITE RECORD. The legacy builds no cover sheet at all when the part
       has no ptp_det row for the site. The connector still builds one, with
       QtyPallet blank, and the fallback does NOT fire: with no item-site row
       there is no ord_mult to be 0. KNOWN-TEMPORARY: SOL-1737 (after cutover)
       will make this case a not-found or a flag. Until then this behaviour
       stays.

       UNKNOWN ord_mult is not 0 (ABL: "? <> 0" is TRUE), so the fallback does
       not fire. That matches the legacy, where STRING(?) never equals "0", and
       the value returned is the same STRING() of the same field that the
       pre-SOL-1736 code returned. */
    METHOD PUBLIC STATIC CHARACTER ResolveQtyPallet(INPUT plSiteRecordFound AS LOGICAL,
                                                    INPUT pdOrderMultiple   AS DECIMAL,
                                                    INPUT plCustomerMatched AS LOGICAL,
                                                    INPUT pcCustomerComment AS CHARACTER):
        /* "<> TRUE", not "NOT": an unknown flag must take the blank branch,
           and "IF NOT ?" would fall through instead. */
        IF plSiteRecordFound <> TRUE THEN
            RETURN "":U.

        IF pdOrderMultiple <> 0 THEN
            RETURN STRING(pdOrderMultiple).

        /* ord_mult is 0: the live legacy fallback */
        IF plCustomerMatched = TRUE THEN
            RETURN pcCustomerComment.

        /* 1b: the legacy prints "0" here -- blank by ruling (SOL-1736 1b) */
        RETURN "":U.
    END METHOD.

END CLASS.
