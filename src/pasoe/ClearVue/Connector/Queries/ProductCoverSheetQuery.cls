/* SPDX-License-Identifier: Apache-2.0 */
/*------------------------------------------------------------------------
    File        : ProductCoverSheetQuery.cls
    Package     : ClearVue.Connector.Queries
    Purpose     : Combined product cover sheet for a part at a facility ->
                  header + structure + (embedded-shape) route + comments,
                  shaped to the contract CoverSheet envelope.

    Ports the LOGIC of the legacy xx-rprdcvr.p + inc/CoverSheetTT.i (reference
    only; names/shape not carried forward -- canonical ClearVue names emitted).

    COMPOSES the already-built pieces rather than re-porting them (the prompt's
    "reuse the structure component already built"):
      - Structure -> ProductStructureQuery (the canonical full multi-level BOM
        explosion, xx-bmpsrp.p logic). NOTE this deliberately REPLACES the
        legacy cover sheet's shallow, MPI-specific 2-level ps_mstr walk (its
        "91-"/"03-12"/"04-08" phantom filters). The cover sheet now shows the
        same canonical structure as /product-structure -- one BOM truth.
      - Route -> ProductRouteQuery, rendered in its FULL shape (PiecesPerHour +
        WorkCenterDescription included) with its harvested Comments.
    Only the cover-sheet HEADER is unique to this class.

    HEADER PORT (live joins only): pt_mstr (desc/rev/draw/bom-code) + ptp_det
    (routing/pallet-mult/site bom-code) + the customer chain
    cp_mstr -> cm_mstr -> ad_mstr (shipto/shipname/customer-item, plus the
    matched customer part's comment for the QtyPallet fallback).

    QTY/PALLET (SOL-1736): ptp_ord_mult when it is non-zero. When it is 0, the
    cp_comment of the SAME cp_mstr record ResolveCustomer picks for ShipTo /
    CustItem -- the legacy cploop's "IF pallet_qty = '0' THEN pallet_qty =
    cp_comment". That fallback is LIVE legacy code. An earlier version of this
    header filed it under the dead paths below, which was wrong. It is ported
    verbatim: cp_comment is free text, so no TRIM and no numeric check. The
    rule lives on CoverSheetRules:ResolveQtyPallet, with its two blank cases:
    no matched customer (ruled 2026-10-22, SOL-1736 1b: blank, not the
    legacy "0") and no site record (known-temporary until SOL-1737).

    NOT PORTED (dead legacy paths -- flagged, emit null/blank):
      - The PQ.txt and prdlist.prn file imports, and the t-pallet / t-pick
        temp-tables they filled. Both imports are commented out in the legacy,
        so t-pallet's SECOND QtyPallet fallback (after the cp_comment one) and
        chkCust's t-pick ShipTo/ShipName override can never fire. (An older
        copy of the legacy program, from before the imports were commented
        out, still has them live; the current copy is the reference.)
      - Note1..Note10 (SOL-173): the legacy sourced these from chkCust's t-shp,
        populated from a dead prdlist.prn import -- so they were effectively
        always blank. Emitted as null here (contract documents them UNPOPULATED,
        pending a real notes source -- a consumer must not read null as "no
        notes"). Wiring a source is out of scope for SOL-173.

    EXISTENCE: a real pt_mstr lookup (PartExists()); a part absent from pt_mstr
    -> caller 404. A part that exists returns 200 with whatever header/structure/
    route/comments are available (any of the arrays may be empty).

    One responsibility: assemble the cover-sheet pieces. No JSON, no auth, no HTTP.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING ClearVue.Connector.Config.ConnectorConfig.
USING ClearVue.Connector.Data.DatabaseConnection.
USING ClearVue.Connector.Queries.ProductStructureQuery.
USING ClearVue.Connector.Queries.ProductRouteQuery.
USING ClearVue.Connector.Queries.CoverSheetRules.
USING ClearVue.Connector.Web.ConnectorError.
USING ClearVue.Connector.Web.ErrorClassifier.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Queries.ProductCoverSheetQuery:

    DEFINE PRIVATE VARIABLE oConfig    AS ConnectorConfig    NO-UNDO.
    DEFINE PRIVATE VARIABLE oDb        AS DatabaseConnection NO-UNDO.
    DEFINE PRIVATE VARIABLE oStructure AS ProductStructureQuery NO-UNDO.
    DEFINE PRIVATE VARIABLE oRoute     AS ProductRouteQuery     NO-UNDO.

    /* Contract CoverSheetHeader shape (single row), canonical names. */
    DEFINE PRIVATE TEMP-TABLE ttCoverHeader NO-UNDO
        FIELD ShipTo        AS CHARACTER
        FIELD ShipName      AS CHARACTER
        FIELD PartNumber    AS CHARACTER
        FIELD AltPartNumber AS CHARACTER
        FIELD Revision      AS CHARACTER
        FIELD Description   AS CHARACTER
        FIELD Bom           AS CHARACTER
        FIELD CustItem      AS CHARACTER
        FIELD RouteCode     AS CHARACTER
        FIELD QtyPallet     AS CHARACTER
        FIELD Note1  AS CHARACTER  FIELD Note2  AS CHARACTER
        FIELD Note3  AS CHARACTER  FIELD Note4  AS CHARACTER
        FIELD Note5  AS CHARACTER  FIELD Note6  AS CHARACTER
        FIELD Note7  AS CHARACTER  FIELD Note8  AS CHARACTER
        FIELD Note9  AS CHARACTER  FIELD Note10 AS CHARACTER.

    DEFINE PRIVATE VARIABLE cDomain    AS CHARACTER NO-UNDO.
    DEFINE PRIVATE VARIABLE cPartNo    AS CHARACTER NO-UNDO.
    DEFINE PRIVATE VARIABLE lPartFound AS LOGICAL   NO-UNDO.

    CONSTRUCTOR PUBLIC ProductCoverSheetQuery(INPUT poConfig AS ConnectorConfig,
                                              INPUT poDb     AS DatabaseConnection):
        ASSIGN
            oConfig = poConfig
            oDb     = poDb.
    END CONSTRUCTOR.

    /* ---- result accessors (by HANDLE, like the sibling queries) ---- */
    METHOD PUBLIC HANDLE GetHeaderHandle():
        RETURN TEMP-TABLE ttCoverHeader:HANDLE.
    END METHOD.
    METHOD PUBLIC HANDLE GetStructureHandle():
        RETURN oStructure:GetResultsHandle().
    END METHOD.
    METHOD PUBLIC HANDLE GetRouteHandle():
        RETURN oRoute:GetResultsHandle().
    END METHOD.
    METHOD PUBLIC HANDLE GetCommentsHandle():
        RETURN oRoute:GetCommentsHandle().
    END METHOD.
    METHOD PUBLIC CHARACTER GetPartNumber():
        RETURN cPartNo.
    END METHOD.
    METHOD PUBLIC LOGICAL PartExists():
        RETURN lPartFound.
    END METHOD.

    /* Assemble the cover sheet. THROWs ConnectorError on connectivity/query
       failure (same classification as the sibling queries). Check PartExists()
       for the 404 decision. */
    METHOD PUBLIC VOID Execute(INPUT pcPart AS CHARACTER,
                               INPUT pcSite AS CHARACTER):
        DEFINE VARIABLE oClassified AS ConnectorError NO-UNDO.
        DEFINE VARIABLE oFallback   AS ConnectorError NO-UNDO.

        EMPTY TEMP-TABLE ttCoverHeader.
        ASSIGN
            cPartNo    = pcPart
            lPartFound = FALSE
            cDomain    = oConfig:ErpDomain.

        IF cDomain = "":U THEN
            UNDO, THROW ConnectorError:Internal(
                "ERP domain is not configured (CLEARVUE_ERP_DOMAIN).":U).

        oDb:EnsureConnected().

        /* existence gate first -- no header/structure/route work for a part
           that is not in the ERP */
        IF NOT PartInMaster(INPUT pcPart) THEN
            RETURN.   /* lPartFound FALSE -> caller returns 404 */
        lPartFound = TRUE.

        BuildHeader(INPUT pcPart, INPUT pcSite).

        /* reuse the canonical structure + route engines */
        oStructure = NEW ProductStructureQuery(oConfig, oDb).
        oStructure:Execute(INPUT pcPart, INPUT pcSite).

        oRoute = NEW ProductRouteQuery(oConfig, oDb).
        oRoute:Execute(INPUT pcPart, INPUT pcSite).

        RETURN.

        CATCH oConnErr AS ConnectorError:
            UNDO, THROW oConnErr.
        END CATCH.
        CATCH oErr AS Progress.Lang.Error:
            oClassified = ErrorClassifier:ClassifyConnectionState(oErr).
            IF VALID-OBJECT(oClassified) THEN
                UNDO, THROW oClassified.

            oFallback = ConnectorError:ErpQueryError(
                "cover-sheet query failed unexpectedly":U).
            oFallback:RawDetail = ErrorClassifier:RawDetailOf(oErr).
            UNDO, THROW oFallback.
        END CATCH.
    END METHOD.

    /* Existence check: does the part exist in pt_mstr for this domain? */
    METHOD PRIVATE LOGICAL PartInMaster(INPUT pcPart AS CHARACTER):
        DEFINE BUFFER bPt FOR pt_mstr.
        FIND FIRST bPt NO-LOCK
            WHERE bPt.pt_domain = cDomain
              AND bPt.pt_part   = pcPart NO-ERROR.
        RETURN AVAILABLE bPt.
    END METHOD.

    /* Build the single header row: part master + item-site + customer chain. */
    METHOD PRIVATE VOID BuildHeader(INPUT pcPart AS CHARACTER,
                                    INPUT pcSite AS CHARACTER):
        DEFINE VARIABLE cBom       AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cRoute     AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cQtyPallet AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cShipTo    AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cShipName  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cCustItem  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lSiteFound     AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE dOrderMultiple AS DECIMAL   NO-UNDO.
        DEFINE VARIABLE lCustMatched   AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE cCustComment   AS CHARACTER NO-UNDO.
        DEFINE BUFFER bPt  FOR pt_mstr.
        DEFINE BUFFER bPtp FOR ptp_det.

        CREATE ttCoverHeader.
        ASSIGN ttCoverHeader.PartNumber = pcPart.

        /* part master */
        FIND FIRST bPt NO-LOCK
            WHERE bPt.pt_domain = cDomain
              AND bPt.pt_part   = pcPart NO-ERROR.
        IF AVAILABLE bPt THEN
            ASSIGN
                cBom                          = bPt.pt_bom_code
                ttCoverHeader.Description      = bPt.pt_desc1
                ttCoverHeader.Revision        = (IF bPt.pt_rev <> ? THEN bPt.pt_rev ELSE "":U)
                ttCoverHeader.AltPartNumber   = bPt.pt_draw.

        /* item-site: routing, pallet multiple, site-specific bom override */
        FIND FIRST bPtp NO-LOCK
            WHERE bPtp.ptp_domain = cDomain
              AND bPtp.ptp_part   = pcPart
              AND bPtp.ptp_site   = pcSite NO-ERROR.
        IF AVAILABLE bPtp THEN
        DO:
            ASSIGN
                lSiteFound     = TRUE
                dOrderMultiple = bPtp.ptp_ord_mult
                cRoute         = bPtp.ptp_routing.
            IF bPtp.ptp_bom_code <> "":U THEN
                cBom = bPtp.ptp_bom_code.
        END.

        /* customer chain (shipto / shipname / customer item), plus the
           matched record's cp_comment for the QtyPallet fallback */
        ResolveCustomer(INPUT pcPart, OUTPUT cShipTo, OUTPUT cShipName, OUTPUT cCustItem,
                        OUTPUT lCustMatched, OUTPUT cCustComment).

        /* QtyPallet: ptp_ord_mult, or -- when that is 0 -- the matched customer
           part's comment (SOL-1736). The rule and its blank cases are on
           CoverSheetRules:ResolveQtyPallet. */
        cQtyPallet = CoverSheetRules:ResolveQtyPallet(INPUT lSiteFound,
                                                      INPUT dOrderMultiple,
                                                      INPUT lCustMatched,
                                                      INPUT cCustComment).

        ASSIGN
            ttCoverHeader.Bom       = cBom
            ttCoverHeader.RouteCode = cRoute
            ttCoverHeader.QtyPallet = cQtyPallet
            ttCoverHeader.ShipTo    = cShipTo
            ttCoverHeader.ShipName  = cShipName
            ttCoverHeader.CustItem  = cCustItem.
        /* Note1..Note10 intentionally left null -- see class header (dead
           legacy t-shp source). */
        RETURN.
    END METHOD.

    /* cp_mstr -> cm_mstr (7-char address match) -> ad_mstr, per the legacy
       cploop. First customer part wins. All optional -> blank when absent.

       SOL-1736: also returns whether any record matched, and THAT record's
       cp_comment (the QtyPallet fallback). Both are taken inside this one
       loop, from the one bCp row that sets ShipTo / CustItem, so the
       fallback can never come from a different customer-part record. A
       separate cp_mstr lookup could: the first cp_mstr row for the part need
       not be the one whose customer matches. */
    METHOD PRIVATE VOID ResolveCustomer(INPUT  pcPart        AS CHARACTER,
                                        OUTPUT pcShipTo      AS CHARACTER,
                                        OUTPUT pcShipName    AS CHARACTER,
                                        OUTPUT pcCustItem    AS CHARACTER,
                                        OUTPUT plMatched     AS LOGICAL,
                                        OUTPUT pcCustComment AS CHARACTER):
        DEFINE BUFFER bCp FOR cp_mstr.
        DEFINE BUFFER bCm FOR cm_mstr.
        DEFINE BUFFER bAd FOR ad_mstr.

        ASSIGN pcShipTo = "":U  pcShipName = "":U  pcCustItem = "":U
               plMatched = FALSE  pcCustComment = "":U.

        cploop:
        FOR EACH bCp NO-LOCK
            WHERE bCp.cp_domain = cDomain
              AND bCp.cp_part   = pcPart:

            FIND FIRST bCm NO-LOCK
                WHERE bCm.cm_domain = cDomain
                  AND SUBSTRING(bCm.cm_addr, 1, 7) = SUBSTRING(bCp.cp_cust, 1, 7) NO-ERROR.
            IF NOT AVAILABLE bCm THEN
                NEXT cploop.

            ASSIGN
                plMatched     = TRUE
                pcShipTo      = bCp.cp_cust
                pcCustItem    = bCp.cp_cust_part
                pcCustComment = bCp.cp_comment.

            FIND FIRST bAd NO-LOCK
                WHERE bAd.ad_domain = cDomain
                  AND bAd.ad_addr   = bCm.cm_addr NO-ERROR.
            IF AVAILABLE bAd THEN
                pcShipName = bAd.ad_name.

            LEAVE cploop.
        END.
        RETURN.
    END METHOD.

END CLASS.
