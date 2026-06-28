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
        JsonFormat:AddDateOrNull(oJson, "EndDate":U,   ?).
        Assert:Equals("2026-01-15":U, oJson:GetCharacter("StartDate":U)).
        Assert:IsTrue(oJson:IsNull("EndDate":U)).
    END METHOD.

    @Test.
    METHOD PUBLIC VOID DisconnectClassifier_recognizes_documented_codes():
        Assert:IsTrue(DatabaseConnection:IsDisconnectError(1423)).
        Assert:IsTrue(DatabaseConnection:IsDisconnectError(1422)).
        Assert:IsFalse(DatabaseConnection:IsDisconnectError(0)).
        /* a random app error must NOT be treated as a disconnect */
        Assert:IsFalse(DatabaseConnection:IsDisconnectError(132)).
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
        Assert:IsFalse(oAuth:IsAuthorizedHeader(?)).
        Assert:IsFalse(oAuth:IsAuthorizedHeader("Bearer anything":U)).
    END METHOD.

END CLASS.
