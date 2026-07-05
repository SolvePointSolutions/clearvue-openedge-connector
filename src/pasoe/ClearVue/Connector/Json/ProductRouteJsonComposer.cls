/* SPDX-License-Identifier: Apache-2.0 */
/*------------------------------------------------------------------------
    File        : ProductRouteJsonComposer.cls
    Package     : ClearVue.Connector.Json
    Purpose     : Compose the contract RouteStep[] JSON for /product-route from
                  a ProductRouteQuery result, by HAND via the JSON Object Model.

    STANDALONE SHAPE. The contract marks PiecesPerHour and WorkCenterDescription
    as "cover-sheet route only" -- this composer deliberately OMITS both (and
    ignores the harvested comments). The cover sheet uses its own composer
    (ProductCoverSheetJsonComposer) to render the full route row + comments from
    the SAME ProductRouteQuery temp-table.

    Canonical field names are set explicitly member-by-member (JSON Object Model,
    not WRITE-JSON + SERIALIZE-NAME) so stock output == SaaS ErpRouteStep ==
    identity. OperationNumber is required (always present); every other field
    empty/unknown -> JSON null; decimals emitted as invariant numbers at the
    contract scale.

    One responsibility: route rows -> contract JSON string. No DB, no auth, no HTTP.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING ClearVue.Connector.Json.JsonFormat.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Json.ProductRouteJsonComposer:

    /* Contract wire-format scales (feasibility-11.6 §3). */
    DEFINE PRIVATE VARIABLE iSetupScale AS INTEGER NO-UNDO INITIAL 3.
    DEFINE PRIVATE VARIABLE iRunScale   AS INTEGER NO-UNDO INITIAL 9.
    DEFINE PRIVATE VARIABLE iWaitScale  AS INTEGER NO-UNDO INITIAL 3.
    DEFINE PRIVATE VARIABLE iMoveScale  AS INTEGER NO-UNDO INITIAL 3.
    DEFINE PRIVATE VARIABLE iYieldScale AS INTEGER NO-UNDO INITIAL 2.

    /* Compose the standalone RouteStep[] from the query result temp-table
       HANDLE (rows in SeqNo/ro_op order). */
    METHOD PUBLIC LONGCHAR Compose(INPUT phTable AS HANDLE):
        DEFINE VARIABLE oArray  AS JsonArray  NO-UNDO.
        DEFINE VARIABLE lcOut   AS LONGCHAR   NO-UNDO.

        oArray = ComposeArray(INPUT phTable).
        oArray:Write(OUTPUT lcOut).
        RETURN lcOut.
    END METHOD.

    /* Shared with the cover-sheet composer: build the JsonArray of standard
       RouteStep rows (no PiecesPerHour/WorkCenterDescription). The cover-sheet
       composer calls ComposeArrayFull() instead for the enriched shape. */
    METHOD PUBLIC JsonArray ComposeArray(INPUT phTable AS HANDLE):
        RETURN BuildArray(INPUT phTable, INPUT FALSE).
    END METHOD.

    /* Cover-sheet shape: the same rows PLUS PiecesPerHour + WorkCenterDescription. */
    METHOD PUBLIC JsonArray ComposeArrayFull(INPUT phTable AS HANDLE):
        RETURN BuildArray(INPUT phTable, INPUT TRUE).
    END METHOD.

    METHOD PRIVATE JsonArray BuildArray(INPUT phTable AS HANDLE,
                                        INPUT plCoverSheet AS LOGICAL):
        DEFINE VARIABLE oArray  AS JsonArray  NO-UNDO.
        DEFINE VARIABLE oRow    AS JsonObject NO-UNDO.
        DEFINE VARIABLE hBuffer AS HANDLE     NO-UNDO.
        DEFINE VARIABLE hQuery  AS HANDLE     NO-UNDO.

        oArray  = NEW JsonArray().
        hBuffer = phTable:DEFAULT-BUFFER-HANDLE.

        CREATE QUERY hQuery.
        hQuery:SET-BUFFERS(hBuffer).
        hQuery:QUERY-PREPARE("FOR EACH " + hBuffer:NAME + " NO-LOCK BY SeqNo":U).
        hQuery:QUERY-OPEN().

        hQuery:GET-FIRST().
        DO WHILE hBuffer:AVAILABLE:
            oRow = NEW JsonObject().
            /* required field always present */
            JsonFormat:AddString(oRow, "OperationNumber":U,
                hBuffer:BUFFER-FIELD("OperationNumber":U):BUFFER-VALUE).
            JsonFormat:AddStringOrNull(oRow, "StandardOperation":U,
                hBuffer:BUFFER-FIELD("StandardOperation":U):BUFFER-VALUE).
            JsonFormat:AddStringOrNull(oRow, "Description":U,
                hBuffer:BUFFER-FIELD("Description":U):BUFFER-VALUE).
            JsonFormat:AddStringOrNull(oRow, "WorkCenterId":U,
                hBuffer:BUFFER-FIELD("WorkCenterId":U):BUFFER-VALUE).
            JsonFormat:AddStringOrNull(oRow, "Machine":U,
                hBuffer:BUFFER-FIELD("Machine":U):BUFFER-VALUE).
            JsonFormat:AddDateOrNull(oRow, "StartDate":U,
                hBuffer:BUFFER-FIELD("StartDate":U):BUFFER-VALUE).
            JsonFormat:AddDateOrNull(oRow, "EndDate":U,
                hBuffer:BUFFER-FIELD("EndDate":U):BUFFER-VALUE).
            JsonFormat:AddNumber(oRow, "SetupHours":U,
                hBuffer:BUFFER-FIELD("SetupHours":U):BUFFER-VALUE, iSetupScale).
            JsonFormat:AddNumber(oRow, "RunHoursPerPiece":U,
                hBuffer:BUFFER-FIELD("RunHoursPerPiece":U):BUFFER-VALUE, iRunScale).
            JsonFormat:AddNumber(oRow, "Wait":U,
                hBuffer:BUFFER-FIELD("Wait":U):BUFFER-VALUE, iWaitScale).
            JsonFormat:AddNumber(oRow, "Move":U,
                hBuffer:BUFFER-FIELD("Move":U):BUFFER-VALUE, iMoveScale).
            JsonFormat:AddNumber(oRow, "YieldPercent":U,
                hBuffer:BUFFER-FIELD("YieldPercent":U):BUFFER-VALUE, iYieldScale).
            JsonFormat:AddStringOrNull(oRow, "Tool":U,
                hBuffer:BUFFER-FIELD("Tool":U):BUFFER-VALUE).

            /* cover-sheet-only fields: present on the cover sheet, omitted on
               standalone /product-route */
            IF plCoverSheet THEN
            DO:
                JsonFormat:AddNumber(oRow, "PiecesPerHour":U,
                    hBuffer:BUFFER-FIELD("PiecesPerHour":U):BUFFER-VALUE, 4).
                JsonFormat:AddStringOrNull(oRow, "WorkCenterDescription":U,
                    hBuffer:BUFFER-FIELD("WorkCenterDescription":U):BUFFER-VALUE).
            END.

            oArray:Add(oRow).
            hQuery:GET-NEXT().
        END.

        RETURN oArray.

        FINALLY:
            IF VALID-HANDLE(hQuery) THEN
            DO:
                IF hQuery:IS-OPEN THEN hQuery:QUERY-CLOSE().
                DELETE OBJECT hQuery.
            END.
        END FINALLY.
    END METHOD.

END CLASS.
