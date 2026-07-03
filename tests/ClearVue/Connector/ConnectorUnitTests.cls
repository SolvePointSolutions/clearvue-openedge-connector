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

    DB-bound behavior (the BOM explosion against pt_mstr/ps_mstr/ptp_det, the
    live reconnect, and latency) CANNOT be unit-tested off a connected MFG/PRO
    schema -- those are the [LIVE-ONLY] steps in docs/deploy-and-run-11.6.md.

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

END CLASS.
