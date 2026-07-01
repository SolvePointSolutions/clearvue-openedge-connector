/*------------------------------------------------------------------------
    File        : ConnectorError.cls
    Package     : ClearVue.Connector.Web
    Purpose     : Typed, structured connector error -> contract `Error` body.

    Mirrors the OpenAPI `Error` schema EXACTLY (code, category, retryable,
    message, retryAfterSeconds, correlationId, timestamp, diagnostic). It is
    also a Progress.Lang.AppError subclass so query/data code can THROW it and
    the REST-adapter .p entry seam can CATCH it and render the contract body with
    the right HTTP status (ToJsonString + StatusString) -- one path for every
    failure mode.

    The code<->category<->retryable<->httpStatus mapping lives here so it can
    never drift between entry points. Construct via the static factories.

    One responsibility: represent + render a contract error. No DB, no auth.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Web.ConnectorError INHERITS Progress.Lang.AppError:

    /* Stable machine code (contract enum). */
    DEFINE PUBLIC PROPERTY Code AS CHARACTER NO-UNDO
        GET. PRIVATE SET.
    /* Coarse class. */
    DEFINE PUBLIC PROPERTY Category AS CHARACTER NO-UNDO
        GET. PRIVATE SET.
    DEFINE PUBLIC PROPERTY Retryable AS LOGICAL NO-UNDO
        GET. PRIVATE SET.
    DEFINE PUBLIC PROPERTY SafeMessage AS CHARACTER NO-UNDO
        GET. PRIVATE SET.
    DEFINE PUBLIC PROPERTY RetryAfterSeconds AS INTEGER NO-UNDO
        GET. PRIVATE SET.
    DEFINE PUBLIC PROPERTY Diagnostic AS CHARACTER NO-UNDO
        GET. PRIVATE SET.
    DEFINE PUBLIC PROPERTY CorrelationId AS CHARACTER NO-UNDO
        GET. SET.
    /* HTTP status the WebHandler must put on the wire for this error. */
    DEFINE PUBLIC PROPERTY HttpStatus AS INTEGER NO-UNDO
        GET. PRIVATE SET.

    CONSTRUCTOR PRIVATE ConnectorError(INPUT pcCode      AS CHARACTER,
                                       INPUT pcCategory  AS CHARACTER,
                                       INPUT plRetryable AS LOGICAL,
                                       INPUT piHttp      AS INTEGER,
                                       INPUT piRetryAfter AS INTEGER,
                                       INPUT pcMessage   AS CHARACTER,
                                       INPUT pcDiagnostic AS CHARACTER):
        SUPER(pcMessage).
        ASSIGN
            THIS-OBJECT:Code              = pcCode
            THIS-OBJECT:Category          = pcCategory
            THIS-OBJECT:Retryable         = plRetryable
            THIS-OBJECT:HttpStatus        = piHttp
            THIS-OBJECT:RetryAfterSeconds = piRetryAfter
            THIS-OBJECT:SafeMessage       = pcMessage
            THIS-OBJECT:Diagnostic        = pcDiagnostic.
    END CONSTRUCTOR.

    /* ---- Factories: one per contract code, mapping baked in. ---- */

    METHOD PUBLIC STATIC ConnectorError BadRequest(INPUT pcMessage AS CHARACTER):
        RETURN NEW ConnectorError("BAD_REQUEST":U, "REQUEST":U, FALSE, 400, 0,
                                  pcMessage, ?).
    END METHOD.

    METHOD PUBLIC STATIC ConnectorError Unauthorized():
        RETURN NEW ConnectorError("UNAUTHORIZED":U, "AUTH":U, FALSE, 401, 0,
                                  "Missing or invalid credentials.":U, ?).
    END METHOD.

    METHOD PUBLIC STATIC ConnectorError NotFound(INPUT pcMessage AS CHARACTER):
        RETURN NEW ConnectorError("NOT_FOUND":U, "DATA":U, FALSE, 404, 0,
                                  pcMessage, ?).
    END METHOD.

    /* Existing connection dropped (DB restart) and reconnect failed in budget. */
    METHOD PUBLIC STATIC ConnectorError ErpDisconnected(INPUT pcDiagnostic AS CHARACTER):
        RETURN NEW ConnectorError("ERP_DISCONNECTED":U, "ERP_CONNECTIVITY":U, TRUE, 503, 5,
                                  "ERP database is restarting; retry shortly.":U,
                                  pcDiagnostic).
    END METHOD.

    /* Host/broker not reachable at all. */
    METHOD PUBLIC STATIC ConnectorError ErpUnavailable(INPUT pcDiagnostic AS CHARACTER):
        RETURN NEW ConnectorError("ERP_UNAVAILABLE":U, "ERP_CONNECTIVITY":U, TRUE, 503, 5,
                                  "ERP database is unreachable.":U,
                                  pcDiagnostic).
    END METHOD.

    METHOD PUBLIC STATIC ConnectorError ErpTimeout(INPUT pcDiagnostic AS CHARACTER):
        RETURN NEW ConnectorError("ERP_TIMEOUT":U, "ERP_CONNECTIVITY":U, TRUE, 504, 3,
                                  "ERP query exceeded the time budget.":U,
                                  pcDiagnostic).
    END METHOD.

    METHOD PUBLIC STATIC ConnectorError ErpQueryError(INPUT pcDiagnostic AS CHARACTER):
        RETURN NEW ConnectorError("ERP_QUERY_ERROR":U, "INTERNAL":U, FALSE, 502, 0,
                                  "ERP query failed.":U,
                                  pcDiagnostic).
    END METHOD.

    METHOD PUBLIC STATIC ConnectorError Internal(INPUT pcDiagnostic AS CHARACTER):
        RETURN NEW ConnectorError("INTERNAL":U, "INTERNAL":U, FALSE, 500, 0,
                                  "An unexpected connector error occurred.":U,
                                  pcDiagnostic).
    END METHOD.

    /* Render the contract Error body. Null/empty optional fields are omitted
       (or null where the contract marks them nullable). */
    METHOD PUBLIC JsonObject ToJson():
        DEFINE VARIABLE oJson AS JsonObject NO-UNDO.
        oJson = NEW JsonObject().

        oJson:Add("code":U,      THIS-OBJECT:Code).
        oJson:Add("category":U,  THIS-OBJECT:Category).
        oJson:Add("retryable":U, THIS-OBJECT:Retryable).

        IF THIS-OBJECT:SafeMessage <> ? AND THIS-OBJECT:SafeMessage <> "":U THEN
            oJson:Add("message":U, THIS-OBJECT:SafeMessage).

        IF THIS-OBJECT:RetryAfterSeconds > 0 THEN
            oJson:Add("retryAfterSeconds":U, THIS-OBJECT:RetryAfterSeconds).

        IF THIS-OBJECT:CorrelationId <> ? AND THIS-OBJECT:CorrelationId <> "":U THEN
            oJson:Add("correlationId":U, THIS-OBJECT:CorrelationId).

        oJson:Add("timestamp":U, ISO-DATE(NOW)).

        IF THIS-OBJECT:Diagnostic <> ? AND THIS-OBJECT:Diagnostic <> "":U THEN
            oJson:Add("diagnostic":U, THIS-OBJECT:Diagnostic).

        RETURN oJson.
    END METHOD.

    /* Convenience for the classic-REST-adapter .p entry seam: render the
       contract Error body straight to LONGCHAR for the OUTPUT param.

       NOTE (OpenEdge 11.6): do NOT chain a method call on a method's return
       value (e.g. THIS-OBJECT:ToJson():Write(...)). Inline method-on-method-
       return chaining is not reliably supported on the 11.6 ABL language level;
       assign the intermediate object to a typed variable first. (Chaining a
       handle attribute like hBuffer:BUFFER-FIELD():BUFFER-VALUE is a different,
       long-supported idiom and is fine.) */
    METHOD PUBLIC LONGCHAR ToJsonString():
        DEFINE VARIABLE oJson  AS JsonObject NO-UNDO.
        DEFINE VARIABLE lcBody AS LONGCHAR   NO-UNDO.
        oJson = THIS-OBJECT:ToJson().
        oJson:Write(OUTPUT lcBody).
        RETURN lcBody.
    END METHOD.

    /* The HTTP status as the CHARACTER code the REST adapter expects from
       RETURN (useReturnValue="true"), e.g. "404", "503". */
    METHOD PUBLIC CHARACTER StatusString():
        RETURN STRING(THIS-OBJECT:HttpStatus).
    END METHOD.

END CLASS.
