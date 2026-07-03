/*------------------------------------------------------------------------
    File        : ProductStructureQuery.cls
    Package     : ClearVue.Connector.Queries
                  (NOT "Query": QUERY is a reserved ABL keyword, and a reserved
                  word as a package/namespace segment makes the type name
                  ClearVue.Connector.Query.ProductStructureQuery unresolvable --
                  every reference raised 5638 "Invalid datatype specified". A
                  package segment MUST avoid reserved words on 11.6.)
    Purpose     : Multi-level product structure (BOM) explosion for a part at
                  a site -> rows shaped to the contract StructureComponent[].

    Ports the LOGIC of the legacy xx-bmpsrp.p (reference only; name not carried
    forward). What the legacy did, re-implemented cleanly:

      1. Resolve the BOM key for the requested part. The structure is keyed by
         a "bom code", not always the bare part: prefer pt_mstr.pt_bom_code,
         then ptp_det.ptp_bom_code (site-specific), else the part itself.
      2. Emit a "Parent" header row for the requested part (pt_mstr / bom_mstr
         enrichment: description, revision, draw#, UOM).
      3. Recursively explode ps_mstr (ps_par -> ps_comp), one level per
         recursion, honoring effectivity (ps_start/ps_end vs as-of TODAY).
      4. Enrich each component from pt_mstr (or bom_mstr fallback for a
         non-inventory parent/phantom).
      5. Stamp an indented Level string per the legacy convention.

    Cleaned up vs legacy:
      - Domain comes from ConnectorConfig (legacy hard-coded "MPI").
      - Read-only NO-LOCK throughout; no NEW SHARED / NEW GLOBAL state.
      - Descriptive temp-table ttProductStructure (legacy tt-ps).
      - CIRCULAR-REFERENCE GUARD: the legacy recursion had no cycle guard; a
        self-referential / cyclic BOM would recurse until the stack blew. We
        track the active parent chain and skip a component already on it.
      - DB resilience delegated to DatabaseConnection:EnsureConnected() before
        any read; connection-loss mid-explosion surfaces as a contract error.

    The temp-table is the connector-internal shape (canonical names).
    ProductStructureJsonComposer composes the JSON array from it via the JSON
    Object Model -- this class does NOT serialize (single responsibility; no
    WRITE-JSON, no munging).

    One responsibility: produce structure rows. No JSON, no auth, no HTTP.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING ClearVue.Connector.Config.ConnectorConfig.
USING ClearVue.Connector.Data.DatabaseConnection.
USING ClearVue.Connector.Web.ConnectorError.
USING ClearVue.Connector.Web.ErrorClassifier.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Queries.ProductStructureQuery:

    DEFINE PRIVATE VARIABLE oConfig AS ConnectorConfig    NO-UNDO.
    DEFINE PRIVATE VARIABLE oDb     AS DatabaseConnection NO-UNDO.

    /* Connector-internal result shape, canonical field names already applied.
       PRIVATE, not PUBLIC: on 11.6 a TEMP-TABLE class data member may only be
       PRIVATE or PROTECTED (only VARIABLE members can be PUBLIC). A PUBLIC
       temp-table fails to compile, which in turn made every class that names
       this type (e.g. GetProductStructure.p) raise 5638. External access is via
       GetResultsHandle() -> TEMP-TABLE:HANDLE, so PRIVATE loses nothing. */
    DEFINE PRIVATE TEMP-TABLE ttProductStructure NO-UNDO
        FIELD SeqNo         AS INTEGER     /* preserve explosion order */
        FIELD Level         AS CHARACTER
        FIELD PartNumber    AS CHARACTER
        FIELD Reference     AS CHARACTER
        FIELD AltPartNumber AS CHARACTER
        FIELD Revision      AS CHARACTER
        FIELD Description   AS CHARACTER
        FIELD Quantity      AS DECIMAL DECIMALS 4
        FIELD UnitOfMeasure AS CHARACTER
        INDEX idxSeq IS PRIMARY SeqNo.

    /* As-of date for effectivity. TODAY matches the legacy default; exposed so
       a future "as of" lookup is config, not a fork. */
    DEFINE PRIVATE VARIABLE dtAsOf  AS DATE    NO-UNDO.
    DEFINE PRIVATE VARIABLE iSeq    AS INTEGER NO-UNDO.
    DEFINE PRIVATE VARIABLE cSite   AS CHARACTER NO-UNDO.
    DEFINE PRIVATE VARIABLE cDomain AS CHARACTER NO-UNDO.
    /* Active parent chain for cycle detection (comma-delimited list). */
    DEFINE PRIVATE VARIABLE cParentChain AS CHARACTER NO-UNDO.

    CONSTRUCTOR PUBLIC ProductStructureQuery(INPUT poConfig AS ConnectorConfig,
                                             INPUT poDb     AS DatabaseConnection):
        ASSIGN
            oConfig = poConfig
            oDb     = poDb.
    END CONSTRUCTOR.

    /* Expose the result temp-table by HANDLE so the JSON composer can iterate
       it with a dynamic query (an instance temp-table member can't be used in a
       static FOR EACH from another class). Rows are in SeqNo (explosion) order. */
    METHOD PUBLIC HANDLE GetResultsHandle():
        RETURN TEMP-TABLE ttProductStructure:HANDLE.
    END METHOD.

    /* Run the explosion. Empties + repopulates ttProductStructure. Returns the
       row count: 0 => the part does NOT exist in pt_mstr (caller -> 404); >=1 =>
       the part exists and the array carries at least the root row (a part with
       no BOM returns exactly 1 -- just the root -- and the caller returns 200).
       THROWs ConnectorError on connectivity/query failure. */
    METHOD PUBLIC INTEGER Execute(INPUT pcPart AS CHARACTER,
                                  INPUT pcSite AS CHARACTER):
        DEFINE VARIABLE oClassified AS ConnectorError NO-UNDO.
        DEFINE VARIABLE oFallback   AS ConnectorError NO-UNDO.

        EMPTY TEMP-TABLE ttProductStructure.
        ASSIGN
            iSeq         = 0
            dtAsOf       = TODAY
            cSite        = pcSite
            cDomain      = oConfig:ErpDomain
            cParentChain = "":U.

        IF cDomain = "":U THEN
            UNDO, THROW ConnectorError:Internal(
                "ERP domain is not configured (CLEARVUE_ERP_DOMAIN).":U).

        /* pre-flight DB gate -- reconnects on a DB-restart drop or throws */
        oDb:EnsureConnected().

        BuildStructure(INPUT pcPart).

        /* iSeq == number of CREATEd rows (one increment per CREATE). */
        RETURN iSeq.

        /* connection lost mid-explosion -> retryable connectivity error */
        CATCH oConnErr AS ConnectorError:
            UNDO, THROW oConnErr.
        END CATCH.
        /* SOL-119: classification step BEFORE the generic fallback. A known
           connection-state fault (1006 db-not-connected, broker down, lost
           connection, ...) anywhere in the message chain becomes a sanitized
           retryable 503; only genuinely unknown faults fall through -- and
           even then the wire diagnostic is sanitized, with the raw message
           preserved server-side in RawDetail (logged by the entry seam,
           keyed by correlationId). */
        CATCH oErr AS Progress.Lang.Error:
            oClassified = ErrorClassifier:ClassifyConnectionState(oErr).
            IF VALID-OBJECT(oClassified) THEN
                UNDO, THROW oClassified.

            oFallback = ConnectorError:ErpQueryError(
                "structure query failed unexpectedly":U).
            oFallback:RawDetail = ErrorClassifier:RawDetailOf(oErr).
            UNDO, THROW oFallback.
        END CATCH.
    END METHOD.

    /* Resolve the BOM key + emit the root row, then explode.

       EXISTENCE GATE (SOL-58, Rod's ruling): the "does the part exist?" test is a
       REAL pt_mstr lookup -- NOT "did the explosion return rows." This is what
       distinguishes the two cases the contract now separates:
         - part NOT in pt_mstr        -> emit NOTHING -> 0 rows -> caller 404s.
         - part IN pt_mstr (any BOM)  -> ALWAYS emit the root row (even childless),
                                         then add children if any -> 200.
       So a real purchased/raw part with no components returns 200 with just the
       root row, instead of the old false-404. */
    METHOD PRIVATE VOID BuildStructure(INPUT pcPart AS CHARACTER):
        DEFINE VARIABLE cBomKey AS CHARACTER NO-UNDO.
        DEFINE BUFFER bPt  FOR pt_mstr.
        DEFINE BUFFER bPtp FOR ptp_det.

        cBomKey = pcPart.

        /* THE existence check: part master lookup. Absent => not found (404). */
        FIND FIRST bPt NO-LOCK
            WHERE bPt.pt_domain = cDomain
              AND bPt.pt_part   = pcPart NO-ERROR.

        IF NOT AVAILABLE bPt THEN
            RETURN.   /* part not in pt_mstr -> no rows -> caller returns 404 */

        /* part header / BOM-code substitution (legacy: pt_bom_code) */
        IF bPt.pt_bom_code <> "":U THEN
            cBomKey = bPt.pt_bom_code.

        /* site-specific BOM-code override (legacy: ptp_det.ptp_bom_code) */
        FIND FIRST bPtp NO-LOCK
            WHERE bPtp.ptp_domain = cDomain
              AND bPtp.ptp_part   = pcPart
              AND bPtp.ptp_site   = cSite NO-ERROR.

        IF AVAILABLE bPtp AND bPtp.ptp_bom_code <> "":U THEN
            cBomKey = bPtp.ptp_bom_code.

        /* part exists -> ALWAYS emit the root row (even if it has no components) */
        EmitParentRow(INPUT pcPart, INPUT cBomKey).

        /* recursive explosion from level 1 (no-op when the part has no BOM) */
        ExplodeLevel(INPUT cBomKey, INPUT 1).
        RETURN.
    END METHOD.

    /* Emit the "Parent" (root) row for the requested part. Only called when the
       part exists in pt_mstr (see BuildStructure existence gate). */
    METHOD PRIVATE VOID EmitParentRow(INPUT pcPart   AS CHARACTER,
                                      INPUT pcBomKey  AS CHARACTER):
        DEFINE BUFFER bPt  FOR pt_mstr.
        DEFINE BUFFER bBom FOR bom_mstr.

        iSeq = iSeq + 1.
        CREATE ttProductStructure.
        ASSIGN
            ttProductStructure.SeqNo      = iSeq
            ttProductStructure.Level      = "Parent":U
            ttProductStructure.PartNumber = pcPart
            /* root has no qty-per-parent; 1 by convention (SOL-58, Rod) so a
               consumer doing arithmetic on Quantity stays safe. Non-nullable. */
            ttProductStructure.Quantity   = 1.

        FIND FIRST bPt NO-LOCK
            WHERE bPt.pt_domain = cDomain AND bPt.pt_part = pcPart NO-ERROR.

        IF AVAILABLE bPt THEN
            ASSIGN
                ttProductStructure.AltPartNumber = bPt.pt_draw
                ttProductStructure.Revision      = (IF bPt.pt_rev <> ? THEN bPt.pt_rev ELSE "":U)
                ttProductStructure.Description    = bPt.pt_desc1
                ttProductStructure.UnitOfMeasure = bPt.pt_um.
        ELSE
        DO:
            /* non-inventory parent -> bom_mstr header */
            FIND FIRST bBom NO-LOCK
                WHERE bBom.bom_domain = cDomain AND bBom.bom_parent = pcBomKey NO-ERROR.
            IF AVAILABLE bBom THEN
                ASSIGN
                    ttProductStructure.Description    = bBom.bom_desc
                    ttProductStructure.UnitOfMeasure = bBom.bom_batch_um.
        END.
        RETURN.
    END METHOD.

    /* One level of explosion. Recurses into each component that itself has a
       structure, guarded against cycles, bounded by effectivity. */
    METHOD PRIVATE VOID ExplodeLevel(INPUT pcParent AS CHARACTER,
                                     INPUT piLevel   AS INTEGER):
        DEFINE BUFFER bPs  FOR ps_mstr.
        DEFINE BUFFER bPt  FOR pt_mstr.
        DEFINE BUFFER bBom FOR bom_mstr.

        DEFINE VARIABLE cDesc AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cUom  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cAlt  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cRev  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iIdx  AS INTEGER   NO-UNDO.

        /* cycle guard: exact comma-list membership (LOOKUP, not CAN-DO/substring,
           so "PART1" and "PART10" never collide). If this parent is already on
           the active chain, a circular BOM exists -- stop, don't recurse. */
        IF LOOKUP(pcParent, cParentChain) > 0 THEN
            RETURN.
        cParentChain = (IF cParentChain = "":U THEN pcParent
                        ELSE cParentChain + "," + pcParent).

        FOR EACH bPs NO-LOCK
            WHERE bPs.ps_domain = cDomain
              AND bPs.ps_par    = pcParent
            BY bPs.ps_op BY bPs.ps_ref BY bPs.ps_comp:

            /* effectivity: include when within [ps_start, ps_end] as of dtAsOf */
            IF NOT IsEffective(INPUT bPs.ps_start, INPUT bPs.ps_end) THEN
                NEXT.

            ASSIGN
                cDesc = "Item not in inventory":U
                cUom  = "":U
                cAlt  = "":U
                cRev  = "":U.

            FIND FIRST bPt NO-LOCK
                WHERE bPt.pt_domain = cDomain AND bPt.pt_part = bPs.ps_comp NO-ERROR.
            IF AVAILABLE bPt THEN
                ASSIGN
                    cDesc    = bPt.pt_desc1
                    cUom     = bPt.pt_um
                    cAlt     = bPt.pt_draw
                    cRev     = (IF bPt.pt_rev <> ? THEN bPt.pt_rev ELSE "":U).
            ELSE
            DO:
                FIND FIRST bBom NO-LOCK
                    WHERE bBom.bom_domain = cDomain
                      AND bBom.bom_parent = bPs.ps_comp NO-ERROR.
                IF AVAILABLE bBom THEN
                    ASSIGN
                        cDesc = bBom.bom_desc
                        cUom  = bBom.bom_batch_um.
            END.

            iSeq = iSeq + 1.
            CREATE ttProductStructure.
            ASSIGN
                ttProductStructure.SeqNo         = iSeq
                ttProductStructure.Level         = BuildLevelLabel(piLevel)
                ttProductStructure.PartNumber    = bPs.ps_comp
                ttProductStructure.Reference     = (IF bPs.ps_ref <> ? THEN bPs.ps_ref ELSE "":U)
                ttProductStructure.AltPartNumber = cAlt
                ttProductStructure.Revision      = cRev
                ttProductStructure.Description    = cDesc
                ttProductStructure.UnitOfMeasure = cUom
                ttProductStructure.Quantity      = bPs.ps_qty_per.

            /* recurse into this component's own structure */
            IF CAN-FIND(FIRST ps_mstr NO-LOCK
                        WHERE ps_mstr.ps_domain = cDomain
                          AND ps_mstr.ps_par    = bPs.ps_comp) THEN
                ExplodeLevel(INPUT bPs.ps_comp, INPUT piLevel + 1).
        END.

        /* pop this parent off the active chain (exact entry, by index). The
           chain is a stack: this parent was pushed last before its children,
           and each child fully restored the chain, so it is the final entry. */
        iIdx = LOOKUP(pcParent, cParentChain).
        IF iIdx > 0 THEN
            ENTRY(iIdx, cParentChain) = "":U.
        /* collapse the emptied slot so LOOKUP stays exact next time */
        cParentChain = TRIM(REPLACE(cParentChain, ",,":U, ",":U), ",":U).
        RETURN.
    END METHOD.

    /* Effectivity test: a component is effective when as-of falls within its
       [start, end] window; unknown (?) bounds are open-ended. */
    METHOD PRIVATE LOGICAL IsEffective(INPUT pdtStart AS DATE,
                                       INPUT pdtEnd   AS DATE):
        IF pdtStart <> ? AND dtAsOf < pdtStart THEN RETURN FALSE.
        IF pdtEnd   <> ? AND dtAsOf > pdtEnd   THEN RETURN FALSE.
        RETURN TRUE.
    END METHOD.

    /* Legacy indented level label, e.g. ".2", "..3" up to 10 chars. */
    METHOD PRIVATE CHARACTER BuildLevelLabel(INPUT piLevel AS INTEGER):
        DEFINE VARIABLE cLvl AS CHARACTER NO-UNDO.
        cLvl = "..........":U.
        cLvl = SUBSTRING(cLvl, 1, MINIMUM(piLevel - 1, 9)) + STRING(piLevel).
        IF LENGTH(cLvl) > 10 THEN
            cLvl = SUBSTRING(cLvl, LENGTH(cLvl) - 9, 10).
        RETURN cLvl.
    END METHOD.

END CLASS.
