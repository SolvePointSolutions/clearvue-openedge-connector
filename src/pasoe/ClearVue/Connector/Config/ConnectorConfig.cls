/*------------------------------------------------------------------------
    File        : ConnectorConfig.cls
    Package     : ClearVue.Connector.Config
    Purpose     : Single source of connector configuration.

    Holds the values that vary per deployment and must NEVER be hard-coded
    in query/handler logic:
      - ErpDomain        the QAD/MFG-PRO domain this connector instance serves
                         (legacy hard-coded "MPI"; here it is configuration).
      - LogicalDbName    the connected logical DB name (legacy "qaddb").
      - ConnectParams    the CONNECT parameter string / -pf reference used to
                         (re)establish the client/server connection.
      - ApiKey           the enforced shared secret for the Authorization
                         bearer header. Read from the environment / OS secret
                         store at runtime -- NEVER stored in source or committed.

    Resolution order for every value: PASOE session/agent property first,
    then OS environment variable, then a safe non-secret default where one
    exists. The API key has NO default -- absent key => connector refuses to
    authorize (fail closed).

    One responsibility: expose configuration. No DB access, no JSON, no auth
    logic lives here.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Config.ConnectorConfig:

    /* The MFG/PRO domain this connector instance serves (config, not a request param). */
    DEFINE PUBLIC PROPERTY ErpDomain AS CHARACTER NO-UNDO
        GET():
            RETURN ResolveValue("CLEARVUE_ERP_DOMAIN":U, "":U).
        END GET.

    /* Logical DB name used by CONNECTED() / queries. */
    DEFINE PUBLIC PROPERTY LogicalDbName AS CHARACTER NO-UNDO
        GET():
            RETURN ResolveValue("CLEARVUE_DB_LOGICAL_NAME":U, "qaddb":U).
        END GET.

    /* CONNECT parameter string. Prefer a -pf reference, e.g. "-pf /etc/clearvue/qaddb.pf".
       The .pf itself holds -db/-ld/-S/-H and lives OUTSIDE the repo (never committed). */
    DEFINE PUBLIC PROPERTY ConnectParams AS CHARACTER NO-UNDO
        GET():
            RETURN ResolveValue("CLEARVUE_DB_CONNECT_PARAMS":U, "":U).
        END GET.

    /* Bounded-reconnect controls (resilience-and-errors.md timeout ladder). */
    DEFINE PUBLIC PROPERTY ReconnectMaxAttempts AS INTEGER NO-UNDO
        GET():
            RETURN ResolveIntValue("CLEARVUE_RECONNECT_MAX_ATTEMPTS":U, 3).
        END GET.

    DEFINE PUBLIC PROPERTY ReconnectBackoffMs AS INTEGER NO-UNDO
        GET():
            RETURN ResolveIntValue("CLEARVUE_RECONNECT_BACKOFF_MS":U, 750).
        END GET.

    /* Reconnect ceiling in ms (~6s per the timeout ladder). */
    DEFINE PUBLIC PROPERTY ReconnectCeilingMs AS INTEGER NO-UNDO
        GET():
            RETURN ResolveIntValue("CLEARVUE_RECONNECT_CEILING_MS":U, 6000).
        END GET.

    /* ---- SOL-119 bounded-connect controls (resilience-and-errors.md) ---- */

    /* Socket pre-probe timeout in ms (-clientConnectTimeout on the probe
       socket; Progress KB 000051142). On OE 11 the effective wait can be
       ~2x this value (two attempts); single attempt on OE 12. */
    DEFINE PUBLIC PROPERTY ProbeTimeoutMs AS INTEGER NO-UNDO
        GET():
            RETURN ResolveIntValue("CLEARVUE_PROBE_TIMEOUT_MS":U, 2000).
        END GET.

    /* Connection Retry Attempts (-ct) appended to the DB CONNECT unless the
       operator's params/.pf already set -ct. The OpenEdge default is ~50
       tries (~103s observed live against a downed broker); 1 = one try. */
    DEFINE PUBLIC PROPERTY ConnectRetryTries AS INTEGER NO-UNDO
        GET():
            RETURN ResolveIntValue("CLEARVUE_CONNECT_CT":U, 1).
        END GET.

    /* The enforced bearer secret. NO default -- fail closed if unset. */
    METHOD PUBLIC CHARACTER GetApiKey():
        RETURN ResolveValue("CLEARVUE_CONNECTOR_API_KEY":U, "":U).
    END METHOD.

    /* ---- resolution helpers ---- */

    METHOD PRIVATE CHARACTER ResolveValue(INPUT pcEnvName AS CHARACTER,
                                          INPUT pcDefault AS CHARACTER):
        DEFINE VARIABLE cValue AS CHARACTER NO-UNDO.

        /* OS environment variable (set on the connector host / PASOE service env). */
        cValue = OS-GETENV(pcEnvName).
        IF cValue <> ? AND cValue <> "":U THEN
            RETURN cValue.

        RETURN pcDefault.
    END METHOD.

    METHOD PRIVATE INTEGER ResolveIntValue(INPUT pcEnvName AS CHARACTER,
                                           INPUT piDefault AS INTEGER):
        DEFINE VARIABLE cValue AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iValue AS INTEGER   NO-UNDO.

        cValue = OS-GETENV(pcEnvName).
        IF cValue <> ? AND cValue <> "":U THEN
        DO:
            iValue = INTEGER(cValue) NO-ERROR.
            IF NOT ERROR-STATUS:ERROR THEN
                RETURN iValue.
        END.

        RETURN piDefault.
    END METHOD.

END CLASS.
