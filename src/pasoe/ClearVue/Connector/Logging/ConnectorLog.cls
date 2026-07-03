/*------------------------------------------------------------------------
    File        : ConnectorLog.cls
    Package     : ClearVue.Connector.Logging
    Purpose     : SOL-119 -- the server-side sink for RAW error detail that
                  must never cross the wire.

    The client Error envelope carries only stable sanitized text plus a
    correlationId; the raw detail (fully-qualified class name, logical db
    name, OE error numbers such as 1006) is written HERE, to the PASOE
    agent log via LOG-MANAGER, keyed by that correlationId. Support flow:
    client reports correlationId -> grep the agent log for it -> full raw
    diagnostic.

    Log line shape (grep-stable; subsystem "CVERR"):
        CLEARVUE-CONNECTOR correlationId=<id> code=<CODE> detail=<raw>

    Logging is best-effort by design: it must NEVER break a response.
    - No open log file (e.g. an ABLUnit dev session) -> silently skip.
    - Any LOG-MANAGER fault -> swallowed.

    One responsibility: write the raw-detail log line. No HTTP, no DB,
    no classification.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Logging.ConnectorLog:

    /* Write one raw-detail error line keyed by the correlation id.
       No-op when there is no raw detail to record. */
    METHOD PUBLIC STATIC VOID WriteError(INPUT pcCorrelationId AS CHARACTER,
                                         INPUT pcCode          AS CHARACTER,
                                         INPUT pcRawDetail     AS CHARACTER):
        IF pcRawDetail = ? OR TRIM(pcRawDetail) = "":U THEN
            RETURN.

        /* No log file open (bare dev/ABLUnit session) -> nothing to write to.
           On PASOE the agent log is always open. */
        IF LOG-MANAGER:LOGFILE-NAME = ? THEN
            RETURN.

        LOG-MANAGER:WRITE-MESSAGE(
            SUBSTITUTE("CLEARVUE-CONNECTOR correlationId=&1 code=&2 detail=&3":U,
                       (IF pcCorrelationId = ? THEN "":U ELSE pcCorrelationId),
                       (IF pcCode          = ? THEN "":U ELSE pcCode),
                       pcRawDetail),
            "CVERR":U).
        RETURN.

        /* best-effort: a logging fault must never break the response */
        CATCH oIgnored AS Progress.Lang.Error:
            RETURN.
        END CATCH.
    END METHOD.

END CLASS.
