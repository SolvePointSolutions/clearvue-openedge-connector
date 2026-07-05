/*------------------------------------------------------------------------
    File        : ProductStructureJsonComposer.cls
    Package     : ClearVue.Connector.Json
    Purpose     : Compose the contract StructureComponent[] JSON from a
                  ProductStructureQuery result, by HAND via the JSON Object
                  Model (JsonObject / JsonArray).

    Extracted from the old WebHandler so the classic-REST-adapter .p entry seam
    reuses the exact same hand-composition -- canonical field names, invariant
    decimals at per-field scale, empty->null -- and returns a LONGCHAR for the
    .p's OUTPUT param. NOT WRITE-JSON of a dataset: the contract field names +
    shape are canonical and hand-set member by member.

    One responsibility: rows -> contract JSON string. No DB, no auth, no HTTP.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING ClearVue.Connector.Json.JsonFormat.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Json.ProductStructureJsonComposer:

    /* Quantity scale per the contract (feasibility-11.6 §3). */
    DEFINE PRIVATE VARIABLE iQtyScale AS INTEGER NO-UNDO INITIAL 4.

    /* Compose from the result temp-table HANDLE (rows in SeqNo order) to a
       standalone LONGCHAR array (the /product-structure body). */
    METHOD PUBLIC LONGCHAR Compose(INPUT phTable AS HANDLE):
        DEFINE VARIABLE oArray AS JsonArray NO-UNDO.
        DEFINE VARIABLE lcOut  AS LONGCHAR  NO-UNDO.
        oArray = ComposeArray(INPUT phTable).
        oArray:Write(OUTPUT lcOut).
        RETURN lcOut.
    END METHOD.

    /* Build the StructureComponent[] JsonArray from the result temp-table
       HANDLE. Exposed so the cover sheet can embed the SAME structure array
       under its "Structure" member (identical shape, one BOM truth). */
    METHOD PUBLIC JsonArray ComposeArray(INPUT phTable AS HANDLE):
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
            /* required field always present; optionals empty->null */
            JsonFormat:AddString(oRow, "Level":U,
                hBuffer:BUFFER-FIELD("Level":U):BUFFER-VALUE).
            JsonFormat:AddString(oRow, "PartNumber":U,
                hBuffer:BUFFER-FIELD("PartNumber":U):BUFFER-VALUE).
            JsonFormat:AddStringOrNull(oRow, "Reference":U,
                hBuffer:BUFFER-FIELD("Reference":U):BUFFER-VALUE).
            JsonFormat:AddStringOrNull(oRow, "AltPartNumber":U,
                hBuffer:BUFFER-FIELD("AltPartNumber":U):BUFFER-VALUE).
            JsonFormat:AddStringOrNull(oRow, "Revision":U,
                hBuffer:BUFFER-FIELD("Revision":U):BUFFER-VALUE).
            JsonFormat:AddStringOrNull(oRow, "Description":U,
                hBuffer:BUFFER-FIELD("Description":U):BUFFER-VALUE).
            JsonFormat:AddNumber(oRow, "Quantity":U,
                hBuffer:BUFFER-FIELD("Quantity":U):BUFFER-VALUE, iQtyScale).
            JsonFormat:AddStringOrNull(oRow, "UnitOfMeasure":U,
                hBuffer:BUFFER-FIELD("UnitOfMeasure":U):BUFFER-VALUE).
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
