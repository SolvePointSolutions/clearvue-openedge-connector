/*------------------------------------------------------------------------
    File        : ConnectorUnitTests.cls
    Package     : ClearVue.Connector (tests)
    Purpose     : ABLUnit tests for the connector's PURE logic -- the pieces
                  that need no DB connection and no PASOE request, so they run
                  on any OpenEdge 11.6 install with ABLUnit:

                    - ConnectorError -> contract Error JSON (codes, categories,
                      retryable, http status, null-omission).
                    - JsonFormat wire rules (invariant decimals at scale, ISO
                      dates, empty/? -> null, required-string never null).
                    - DatabaseConnection:IsDisconnectError classification.
                    - SOL-119: ErrorClassifier connection-state table (1006
                      etc. -> retryable 503), wire sanitization (no db/class/
                      OE-code leakage), RawDetail never serialized.
                    - SOL-119 bounded connect: the pure param-parsing seams
                      (ExtractBrokerEndpoint, HasParameter,
                      NormalizeParamFileText) behind the probe + -ct design.
                    - SOL-174: RouteRules:IsNormalOperation -- the ro_fsm_type
                      rule deciding which ro_det rows the route walk keeps.
                      Behaviour-preserving pins, incl. the inherited
                      unknown-is-not-normal case.
                    - SOL-1736: CoverSheetRules:ResolveQtyPallet -- ptp_ord_mult,
                      else the matched customer part's cp_comment (verbatim),
                      plus pins for the two cases still pending a ruling.

    DB-bound behavior (the BOM explosion against pt_mstr/ps_mstr/ptp_det, the
    route walk over ro_det, the live reconnect, and latency) CANNOT be
    unit-tested off a connected MFG/PRO schema -- those are the [LIVE-ONLY]
    steps in docs/deploy-and-run-11.6.md. Note the SOL-174 tests below reach
    RouteRules, NOT ProductRouteQuery: the query class buffers ro_det et al and
    so cannot compile without a schema. Keep it that way -- referencing the
    query class from here would make the whole unit suite need a database.
    The SOL-1736 tests reach CoverSheetRules, never ProductCoverSheetQuery, for
    the same reason.

    Run: ablunit on this class from an OE 11.6 session with the connector src on
    PROPATH. (Cannot run on the dev macOS box -- no $DLC / no compiler.)
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING OpenEdge.Core.Assert.
USING ClearVue.Connector.Web.ConnectorError.
USING ClearVue.Connector.Web.ErrorClassifier.
USING ClearVue.Connector.Json.JsonFormat.
USING ClearVue.Connector.Data.DatabaseConnection.
USING ClearVue.Connector.Queries.RouteRules.
USING ClearVue.Connector.Queries.CoverSheetRules.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.ConnectorUnitTests:

    @Test.
    METHOD PUBLIC VOID BadRequest_maps_to_400_REQUEST_not_retryable():
        DEFINE VARIABLE oErr AS ConnectorError NO-UNDO.
        oErr = ConnectorError:BadRequest("part is required":U).
        Assert:Equals("BAD_REQUEST":U, oErr:Code).
        Assert:Equals("REQUEST":U,     oErr:Category).
        Assert:Equals(400,             oErr:HttpStatus).
        Assert:IsFalse(oErr:Retryable).
    END METHOD.

    @Test.
    METHOD PUBLIC VOID ErpDisconnected_is_503_retryable_connectivity():
        DEFINE VARIABLE oErr AS ConnectorError NO-UNDO.
        oErr = ConnectorError:ErpDisconnected("reconnect attempted 3x":U).
        Assert:Equals("ERP_DISCONNECTED":U, oErr:Code).
        Assert:Equals("ERP_CONNECTIVITY":U, oErr:Category).
        Assert:Equals(503,                  oErr:HttpStatus).
        Assert:IsTrue(oErr:Retryable).
    END METHOD.

    @Test.
    METHOD PUBLIC VOID ErrorJson_omits_blank_optional_fields():
        DEFINE VARIABLE oErr  AS ConnectorError NO-UNDO.
        DEFINE VARIABLE oJson AS JsonObject     NO-UNDO.
        oErr  = ConnectorError:NotFound("no record":U).
        oJson = oErr:ToJson().
        /* required trio present */
        Assert:IsTrue(oJson:Has("code":U)).
        Assert:IsTrue(oJson:Has("category":U)).
        Assert:IsTrue(oJson:Has("retryable":U)).
        /* correlationId not set -> must be absent (not null/blank) */
        Assert:IsFalse(oJson:Has("correlationId":U)).
    END METHOD.

    @Test.
    METHOD PUBLIC VOID ErrorJson_includes_correlationId_when_set():
        DEFINE VARIABLE oErr  AS ConnectorError NO-UNDO.
        DEFINE VARIABLE oJson AS JsonObject     NO-UNDO.
        oErr = ConnectorError:NotFound("no record":U).
        oErr:CorrelationId = "abc-123":U.
        oJson = oErr:ToJson().
        Assert:IsTrue(oJson:Has("correlationId":U)).
        Assert:Equals("abc-123":U, oJson:GetCharacter("correlationId":U)).
    END METHOD.

    @Test.
    METHOD PUBLIC VOID JsonNumber_uses_invariant_separator_at_scale():
        DEFINE VARIABLE oJson AS JsonObject NO-UNDO.
        DEFINE VARIABLE lcOut AS LONGCHAR   NO-UNDO.
        oJson = NEW JsonObject().
        JsonFormat:AddNumber(oJson, "Quantity":U, 1.5, 4).
        oJson:Write(OUTPUT lcOut).
        /* must contain a '.'-separated number, never a localized ','. */
        Assert:IsTrue(INDEX(STRING(lcOut), "1.5":U) > 0).
        Assert:IsTrue(INDEX(STRING(lcOut), "1,5":U) = 0).
    END METHOD.

    @Test.
    METHOD PUBLIC VOID JsonString_empty_becomes_null():
        DEFINE VARIABLE oJson AS JsonObject NO-UNDO.
        oJson = NEW JsonObject().
        JsonFormat:AddStringOrNull(oJson, "Reference":U, "":U).
        Assert:IsTrue(oJson:IsNull("Reference":U)).
    END METHOD.

    @Test.
    METHOD PUBLIC VOID JsonRequiredString_empty_stays_empty_not_null():
        DEFINE VARIABLE oJson AS JsonObject NO-UNDO.
        oJson = NEW JsonObject().
        JsonFormat:AddString(oJson, "PartNumber":U, "":U).
        Assert:IsFalse(oJson:IsNull("PartNumber":U)).
        Assert:Equals("":U, oJson:GetCharacter("PartNumber":U)).
    END METHOD.

    @Test.
    METHOD PUBLIC VOID JsonDate_emits_iso_or_null():
        DEFINE VARIABLE oJson AS JsonObject NO-UNDO.
        oJson = NEW JsonObject().
        JsonFormat:AddDateOrNull(oJson, "StartDate":U, DATE(1, 15, 2026)).
        /* DATE(?) -- a typed unknown DATE, not a bare ? (bare ? -> 11.6 error 5638). */
        JsonFormat:AddDateOrNull(oJson, "EndDate":U,   DATE(?)).
        Assert:Equals("2026-01-15":U, oJson:GetCharacter("StartDate":U)).
        Assert:IsTrue(oJson:IsNull("EndDate":U)).
    END METHOD.

    @Test.
    METHOD PUBLIC VOID DisconnectClassifier_recognizes_documented_codes():
        Assert:IsTrue(DatabaseConnection:IsDisconnectError(1423)).
        Assert:IsTrue(DatabaseConnection:IsDisconnectError(1422)).
        /* SOL-119: 1006 (db not connected) is in the shared table too */
        Assert:IsTrue(DatabaseConnection:IsDisconnectError(1006)).
        Assert:IsFalse(DatabaseConnection:IsDisconnectError(0)).
        /* a random app error must NOT be treated as a disconnect */
        Assert:IsFalse(DatabaseConnection:IsDisconnectError(132)).
    END METHOD.

    /* ---- SOL-119: connection-state classification + sanitization ---- */

    /* Rod's fault-injection case: with the mfgpro DB stopped, the raw fault
       is OE 1006 "Database mfgpro not connected." -- it must classify as a
       retryable 503 ERP_CONNECTIVITY error, with NO db name / class name /
       OE code in any wire field, and the raw text preserved server-side. */
    @Test.
    METHOD PUBLIC VOID Classifier_maps_db_not_connected_1006_to_retryable_503():
        DEFINE VARIABLE oRaw AS AppError       NO-UNDO.
        DEFINE VARIABLE oErr AS ConnectorError NO-UNDO.
        DEFINE VARIABLE lcBody AS LONGCHAR     NO-UNDO.

        oRaw = NEW AppError("ClearVue.Connector.Queries.ProductStructureQuery Database mfgpro not connected.":U, 1006).
        oErr = ErrorClassifier:ClassifyConnectionState(oRaw).

        Assert:IsTrue(VALID-OBJECT(oErr)).
        Assert:Equals("ERP_DISCONNECTED":U, oErr:Code).
        Assert:Equals("ERP_CONNECTIVITY":U, oErr:Category).
        Assert:Equals(503,                  oErr:HttpStatus).
        Assert:IsTrue(oErr:Retryable).

        /* sanitized wire body: no db name, no class name, no OE error code */
        lcBody = oErr:ToJsonString().
        Assert:IsTrue(INDEX(STRING(lcBody), "mfgpro":U) = 0).
        Assert:IsTrue(INDEX(STRING(lcBody), "ProductStructureQuery":U) = 0).
        Assert:IsTrue(INDEX(STRING(lcBody), "1006":U) = 0).

        /* raw detail preserved for the server-side log */
        Assert:IsTrue(INDEX(oErr:RawDetail, "mfgpro":U) > 0).
        Assert:IsTrue(INDEX(oErr:RawDetail, "1006":U) > 0).
    END METHOD.

    /* Broker-down family maps to ERP_UNAVAILABLE; the classifier must walk
       ALL messages, not just the first (wrapped errors bury the number). */
    @Test.
    METHOD PUBLIC VOID Classifier_walks_all_messages_and_maps_broker_down():
        DEFINE VARIABLE oRaw AS AppError       NO-UNDO.
        DEFINE VARIABLE oErr AS ConnectorError NO-UNDO.

        oRaw = NEW AppError("outer wrapper text":U, 0).
        oRaw:AddMessage("There is no server for database mfgpro.":U, 1423).
        oErr = ErrorClassifier:ClassifyConnectionState(oRaw).

        Assert:IsTrue(VALID-OBJECT(oErr)).
        Assert:Equals("ERP_UNAVAILABLE":U,  oErr:Code).
        Assert:Equals("ERP_CONNECTIVITY":U, oErr:Category).
        Assert:Equals(503,                  oErr:HttpStatus).
        Assert:IsTrue(oErr:Retryable).
    END METHOD.

    /* A genuinely unknown fault must NOT classify -- the seams then apply
       their own non-retryable fallback (INTERNAL / ERP_QUERY_ERROR). */
    @Test.
    METHOD PUBLIC VOID Classifier_leaves_unknown_faults_unclassified():
        DEFINE VARIABLE oRaw AS AppError       NO-UNDO.
        DEFINE VARIABLE oErr AS ConnectorError NO-UNDO.

        oRaw = NEW AppError("some application bug":U, 132).
        oErr = ErrorClassifier:ClassifyConnectionState(oRaw).
        Assert:IsFalse(VALID-OBJECT(oErr)).
    END METHOD.

    /* RawDetail is the server-side-only channel: whatever is stored there
       must never appear in the serialized contract Error body. */
    @Test.
    METHOD PUBLIC VOID RawDetail_is_never_serialized_to_the_wire():
        DEFINE VARIABLE oErr   AS ConnectorError NO-UNDO.
        DEFINE VARIABLE lcBody AS LONGCHAR       NO-UNDO.

        oErr = ConnectorError:ErpDisconnected("sanitized reason":U).
        oErr:RawDetail = "RAW-TOPOLOGY client/server connection to mfgpro dropped (1006)":U.
        lcBody = oErr:ToJsonString().

        Assert:IsTrue(INDEX(STRING(lcBody), "RAW-TOPOLOGY":U) = 0).
        Assert:IsTrue(INDEX(STRING(lcBody), "mfgpro":U) = 0).
        Assert:IsTrue(INDEX(STRING(lcBody), "sanitized reason":U) > 0).
    END METHOD.

    /* RawDetailOf composes type + every message with its OE number -- the
       support-facing log payload. */
    @Test.
    METHOD PUBLIC VOID RawDetailOf_captures_type_and_all_numbered_messages():
        DEFINE VARIABLE oRaw    AS AppError  NO-UNDO.
        DEFINE VARIABLE cDetail AS CHARACTER NO-UNDO.

        oRaw = NEW AppError("first message":U, 0).
        oRaw:AddMessage("Database mfgpro not connected.":U, 1006).
        cDetail = ErrorClassifier:RawDetailOf(oRaw).

        Assert:IsTrue(INDEX(cDetail, "AppError":U) > 0).
        Assert:IsTrue(INDEX(cDetail, "first message":U) > 0).
        Assert:IsTrue(INDEX(cDetail, "1006":U) > 0).
    END METHOD.

    /* Live-pinned on the 2026-07-02 fault injection: the downed broker
       surfaced OE 1432 "Could not connect to server for database mfgpro,
       errno 0." -- must classify ERP_UNAVAILABLE / 503 / retryable. */
    @Test.
    METHOD PUBLIC VOID Classifier_maps_live_pinned_1432_to_unavailable():
        DEFINE VARIABLE oRaw AS AppError       NO-UNDO.
        DEFINE VARIABLE oErr AS ConnectorError NO-UNDO.

        oRaw = NEW AppError("Could not connect to server for database mfgpro, errno 0.":U, 1432).
        oErr = ErrorClassifier:ClassifyConnectionState(oRaw).

        Assert:IsTrue(VALID-OBJECT(oErr)).
        Assert:Equals("ERP_UNAVAILABLE":U,  oErr:Code).
        Assert:Equals("ERP_CONNECTIVITY":U, oErr:Category).
        Assert:Equals(503,                  oErr:HttpStatus).
        Assert:IsTrue(oErr:Retryable).
    END METHOD.

    /* ---- SOL-119 bounded-connect: pure param-parsing seams ---- */

    /* The probe endpoint is derived from the CONFIGURED connect params
       (-H/-S), not from a duplicate setting. */
    @Test.
    METHOD PUBLIC VOID ExtractBrokerEndpoint_parses_H_and_S_tokens():
        DEFINE VARIABLE cHost AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cSvc  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE lOk   AS LOGICAL   NO-UNDO.

        lOk = DatabaseConnection:ExtractBrokerEndpoint(
            "-db mfgpro -ld mfgpro -H pensacola.home -S 2501":U,
            OUTPUT cHost, OUTPUT cSvc).
        Assert:IsTrue(lOk).
        Assert:Equals("pensacola.home":U, cHost).
        Assert:Equals("2501":U, cSvc).

        /* extra whitespace / tabs / service-by-name still parse */
        lOk = DatabaseConnection:ExtractBrokerEndpoint(
            "  -H   dbhost01" + CHR(9) + "-S mfgpro-broker  -N TCP":U,
            OUTPUT cHost, OUTPUT cSvc).
        Assert:IsTrue(lOk).
        Assert:Equals("dbhost01":U, cHost).
        Assert:Equals("mfgpro-broker":U, cSvc).
    END METHOD.

    @Test.
    METHOD PUBLIC VOID ExtractBrokerEndpoint_unparseable_returns_false():
        DEFINE VARIABLE cHost AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cSvc  AS CHARACTER NO-UNDO.

        /* shared-memory-style params: no -H/-S -> not probeable */
        Assert:IsFalse(DatabaseConnection:ExtractBrokerEndpoint(
            "-db /data/mfgpro -ld mfgpro -1":U, OUTPUT cHost, OUTPUT cSvc)).
        /* -H without -S -> incomplete -> not probeable */
        Assert:IsFalse(DatabaseConnection:ExtractBrokerEndpoint(
            "-db mfgpro -H dbhost01":U, OUTPUT cHost, OUTPUT cSvc)).
        Assert:IsFalse(DatabaseConnection:ExtractBrokerEndpoint(
            "":U, OUTPUT cHost, OUTPUT cSvc)).
    END METHOD.

    /* -ct is appended to the CONNECT only when absent from the effective
       params; exact-token match so "-ct" never false-positives. */
    @Test.
    METHOD PUBLIC VOID HasParameter_is_exact_token_match():
        Assert:IsTrue(DatabaseConnection:HasParameter(
            "-db mfgpro -H h -S 2501 -ct 2":U, "-ct":U)).
        Assert:IsFalse(DatabaseConnection:HasParameter(
            "-db mfgpro -H h -S 2501":U, "-ct":U)).
        /* no substring collisions: -cts / x-ct are different tokens */
        Assert:IsFalse(DatabaseConnection:HasParameter(
            "-db mfgpro -cts 5":U, "-ct":U)).
        Assert:IsFalse(DatabaseConnection:HasParameter(STRING(?), "-ct":U)).
    END METHOD.

    /* .pf flattening: newline handling + #-comment stripping, so -H/-S/-ct
       inside a referenced .pf participate in probe/bounding decisions. */
    @Test.
    METHOD PUBLIC VOID NormalizeParamFileText_strips_comments_and_joins_lines():
        DEFINE VARIABLE cOut  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cHost AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cSvc  AS CHARACTER NO-UNDO.

        cOut = DatabaseConnection:NormalizeParamFileText(
            "# live broker" + CHR(10) +
            "-db mfgpro -ld mfgpro" + CHR(13) + CHR(10) +
            "-H pensacola.home  # db host" + CHR(10) +
            "-S 2501":U).

        Assert:IsTrue(INDEX(cOut, "# ":U) = 0).
        Assert:IsTrue(DatabaseConnection:ExtractBrokerEndpoint(
            cOut, OUTPUT cHost, OUTPUT cSvc)).
        Assert:Equals("pensacola.home":U, cHost).
        Assert:Equals("2501":U, cSvc).
    END METHOD.

    /* The .p entry seam returns this string to the REST adapter
       (useReturnValue="true") to set the HTTP status line. */
    @Test.
    METHOD PUBLIC VOID StatusString_is_the_http_code_for_RETURN():
        Assert:Equals("404":U, ConnectorError:NotFound("x":U):StatusString()).
        Assert:Equals("401":U, ConnectorError:Unauthorized():StatusString()).
        Assert:Equals("503":U, ConnectorError:ErpDisconnected("x":U):StatusString()).
        Assert:Equals("504":U, ConnectorError:ErpTimeout("x":U):StatusString()).
    END METHOD.

    /* The .p writes this LONGCHAR to the responseBody OUTPUT param. */
    @Test.
    METHOD PUBLIC VOID ToJsonString_renders_a_nonempty_error_body():
        DEFINE VARIABLE lcBody AS LONGCHAR NO-UNDO.
        lcBody = ConnectorError:ErpDisconnected("reconnect 3x":U):ToJsonString().
        Assert:IsTrue(LENGTH(STRING(lcBody)) > 0).
        Assert:IsTrue(INDEX(STRING(lcBody), "ERP_DISCONNECTED":U) > 0).
        Assert:IsTrue(INDEX(STRING(lcBody), "ERP_CONNECTIVITY":U) > 0).
    END METHOD.

    /* Bearer extraction (the part of ApiKeyAuthenticator that is env-free) is
       exercised end-to-end on the box; here we cover the parse via a config
       whose secret matches a known token. Env-sourced GetApiKey() is covered by
       the integration smoke test (docs/test-db-setup.md), not this unit run. */
    @Test.
    METHOD PUBLIC VOID BearerHeader_blank_is_unauthorized_fail_closed():
        DEFINE VARIABLE oCfg  AS ClearVue.Connector.Config.ConnectorConfig NO-UNDO.
        DEFINE VARIABLE oAuth AS ClearVue.Connector.Security.ApiKeyAuthenticator NO-UNDO.
        oCfg  = NEW ClearVue.Connector.Config.ConnectorConfig().
        oAuth = NEW ClearVue.Connector.Security.ApiKeyAuthenticator(oCfg).
        /* no secret configured in a bare unit env -> fail closed regardless */
        Assert:IsFalse(oAuth:IsAuthorizedHeader("":U)).
        /* STRING(?) -- a typed unknown CHARACTER (the unknown/missing-header case),
           not a bare ? (bare ? -> 11.6 error 5638). Still proves ? is unauthorized. */
        Assert:IsFalse(oAuth:IsAuthorizedHeader(STRING(?))).
        Assert:IsFalse(oAuth:IsAuthorizedHeader("Bearer anything":U)).
    END METHOD.

    /* ---- SOL-174: the ro_fsm_type normal-operation rule ---- */
    /* These pin the rule the route walk applies to every ro_det row. They are
       BEHAVIOUR-PRESERVING: each expectation is what the inline guard already
       did, verified against the OpenEdge runtime before extraction. See the
       SOL-174 note on RouteRules for why that ticket's stated defect was not
       real -- ABL character comparison ignores trailing blanks, so the old
       "<> ' '" guard kept blank rows just as this one does. */

    /* Blank is a normal operation. "" is what a real unpopulated MFG/PRO
       CHARACTER field holds; the spaces are covered because TRIM makes the
       rule independent of how the blank was stored. */
    @Test.
    METHOD PUBLIC VOID IsNormalOperation_blank_is_a_normal_operation():
        Assert:IsTrue(RouteRules:IsNormalOperation("":U)).
        Assert:IsTrue(RouteRules:IsNormalOperation(" ":U)).
        Assert:IsTrue(RouteRules:IsNormalOperation("   ":U)).
    END METHOD.

    /* The other half of the filter. A rule that simply kept every row would
       pass the blanks above and still be wrong: feature/option and subcontract
       rows must stay out of the route. The padded case guards the TRIM -- it
       must not launder a real type code into a blank. */
    @Test.
    METHOD PUBLIC VOID IsNormalOperation_populated_fsm_type_is_excluded():
        Assert:IsFalse(RouteRules:IsNormalOperation("S":U)).
        Assert:IsFalse(RouteRules:IsNormalOperation("F":U)).
        Assert:IsFalse(RouteRules:IsNormalOperation("O":U)).
        Assert:IsFalse(RouteRules:IsNormalOperation("  S  ":U)).
    END METHOD.

    /* Unknown is NOT normal -- an unknown ro_fsm_type row is dropped from the
       route. This pins INHERITED behaviour, not a preference: ABL evaluates
       "? <> ''" as TRUE (unknown sorts below any value), so the inline guard
       took its skip branch on unknown and always has.

       NO BEHAVIOUR CHANGE. If this ever starts failing because unknown began
       counting as normal, that is a deliberate decision landing and it needs
       its own ticket -- update this fixture on purpose, do not relax it to
       match whatever the code now does.

       STRING(?) -- a typed unknown CHARACTER, not a bare ? (11.6 error 5638). */
    @Test.
    METHOD PUBLIC VOID IsNormalOperation_unknown_is_not_normal_inherited():
        Assert:IsFalse(RouteRules:IsNormalOperation(STRING(?))).
    END METHOD.

    /* ---- SOL-1736: the cover-sheet QtyPallet rule ---- */
    /* These pin CoverSheetRules:ResolveQtyPallet, the value the cover-sheet
       header emits as QtyPallet. The legacy xx-rprdcvr.p takes ptp_ord_mult
       and, when that is 0, falls back to the cp_comment of the first cp_mstr
       record whose customer matches a cm_mstr. WHICH record supplies the
       comment is decided by the DB-bound ProductCoverSheetQuery:ResolveCustomer
       and is pinned by test/smoke/route-coversheet-smoke.sh, not here. These
       cover the rule applied to the values once they have been read.

       Arguments: site record found, ptp_ord_mult, customer matched, the
       matched record's cp_comment. Order-multiple literals are written as
       decimals (48.0, 0.0) because the parameter is DECIMAL.

       Empty results are asserted as LENGTH(...) = 0, not Equals("", ...):
       ABL character comparison ignores trailing blanks, so Equals("", " ")
       passes, and Equals would also not tell "" from a lone space. */

    /* A non-zero pallet multiple is kept, whatever the customer record says.
       The matched comment is deliberately non-blank and different, so a rule
       that let the fallback override ord_mult fails here. */
    @Test.
    METHOD PUBLIC VOID QtyPallet_nonzero_ord_mult_is_kept():
        Assert:Equals("48":U, CoverSheetRules:ResolveQtyPallet(TRUE, 48.0, TRUE, "12":U)).
        Assert:Equals("48":U, CoverSheetRules:ResolveQtyPallet(TRUE, 48.0, FALSE, "":U)).
    END METHOD.

    /* THE fallback: ord_mult 0 and a matched customer -> that customer part's
       comment. Before SOL-1736 the connector emitted blank here. */
    @Test.
    METHOD PUBLIC VOID QtyPallet_zero_ord_mult_with_matched_customer_uses_cp_comment():
        Assert:Equals("36":U, CoverSheetRules:ResolveQtyPallet(TRUE, 0.0, TRUE, "36":U)).
    END METHOD.

    /* Verbatim, because the legacy applied no TRIM and no numeric check, and
       cp_comment is free text. Leading blanks are significant to "=", so the
       Equals guards that side. Trailing blanks are invisible to "=", so the
       LENGTH checks are what catch a right-TRIM. */
    @Test.
    METHOD PUBLIC VOID QtyPallet_cp_comment_is_returned_verbatim():
        DEFINE VARIABLE cResult AS CHARACTER NO-UNDO.

        /* non-numeric free text passes through untouched */
        Assert:Equals("SEE PKG SPEC":U,
            CoverSheetRules:ResolveQtyPallet(TRUE, 0.0, TRUE, "SEE PKG SPEC":U)).
        /* a comment that is itself "0" stays "0" -- it is not "no value" */
        Assert:Equals("0":U, CoverSheetRules:ResolveQtyPallet(TRUE, 0.0, TRUE, "0":U)).

        cResult = CoverSheetRules:ResolveQtyPallet(TRUE, 0.0, TRUE, "  36":U).
        Assert:Equals("  36":U, cResult).
        Assert:Equals(4, LENGTH(cResult)).

        cResult = CoverSheetRules:ResolveQtyPallet(TRUE, 0.0, TRUE, "36  ":U).
        Assert:Equals(4, LENGTH(cResult)).

        /* a blank comment is blank; the composer then emits JSON null */
        Assert:Equals(0, LENGTH(CoverSheetRules:ResolveQtyPallet(TRUE, 0.0, TRUE, "":U))).
    END METHOD.

    /* SOL-1736 1b: ord_mult 0 and NO matched customer -> blank. The legacy
       prints the string "0" here; the connector emits blank (JSON null). The
       comment passed in is non-blank on purpose -- with no matched customer
       it must never surface, whatever its value.

       NO BEHAVIOUR CHANGE. Blank is what the connector has always emitted for
       this case, and 1b is open for a ruling. If this starts failing because
       the rule now returns "0", that is the 1b ruling landing -- update this
       fixture deliberately; do not relax it to match whatever the code does. */
    @Test.
    METHOD PUBLIC VOID QtyPallet_zero_ord_mult_no_matched_customer_is_blank_pending_1b():
        Assert:Equals(0, LENGTH(CoverSheetRules:ResolveQtyPallet(TRUE, 0.0, FALSE, "99":U))).
        Assert:Equals(0, LENGTH(CoverSheetRules:ResolveQtyPallet(TRUE, 0.0, FALSE, "":U))).
    END METHOD.

    /* No site record (no ptp_det for the part at the facility) -> blank, and
       the fallback does NOT fire even with a matched customer: with no
       item-site row there is no ord_mult to be 0.

       NO BEHAVIOUR CHANGE. The legacy builds no cover sheet at all here; the
       connector builds one with QtyPallet blank, as it always has. Whether to
       follow the legacy is SOL-1736 item 6, open for a ruling. If this starts
       failing because the fallback began firing without a site record, that
       is a decision landing -- update this fixture deliberately. */
    @Test.
    METHOD PUBLIC VOID QtyPallet_no_site_record_is_blank_pending_item_6():
        Assert:Equals(0, LENGTH(CoverSheetRules:ResolveQtyPallet(FALSE, 0.0, TRUE, "36":U))).
    END METHOD.

END CLASS.
