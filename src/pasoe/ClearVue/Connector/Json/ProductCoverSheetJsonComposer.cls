/* SPDX-License-Identifier: Apache-2.0 */
/*------------------------------------------------------------------------
    File        : ProductCoverSheetJsonComposer.cls
    Package     : ClearVue.Connector.Json
    Purpose     : Compose the contract CoverSheet envelope JSON from a
                  ProductCoverSheetQuery result, by HAND via the JSON Object
                  Model (JsonObject / JsonArray).

    The nested envelope the feasibility doc calls the "bellwether" -- built
    natively with the JSON Object Model, NOT the legacy WRITE-JSON of a
    ProDataset + REPLACE/TRIM wrapper-munging:

      {
        "PartNumber": "...",
        "Header":     { ShipTo, ShipName, PartNumber, AltPartNumber, Revision,
                        Description, Bom, CustItem, RouteCode, QtyPallet,
                        Note1..Note10 },
        "Structure":  [ StructureComponent, ... ],   <- reuses ProductStructureJsonComposer
        "Route":      [ RouteStep(full), ... ],       <- reuses ProductRouteJsonComposer (full shape)
        "Comments":   [ "line", ... ]                 <- plain string array (not [{comment}])
      }

    The embedded structure array is IDENTICAL to /product-structure's body, and
    the embedded route array is the full RouteStep shape (WITH PiecesPerHour +
    WorkCenterDescription) -- both reused from the sibling composers so there is
    exactly one serialization of each. The legacy "Refinance" SERIALIZE-NAME
    typo does not exist here: the structure composer emits "Reference".

    One responsibility: pieces -> contract CoverSheet JSON string. No DB, no auth.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING ClearVue.Connector.Json.JsonFormat.
USING ClearVue.Connector.Json.ProductStructureJsonComposer.
USING ClearVue.Connector.Json.ProductRouteJsonComposer.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Json.ProductCoverSheetJsonComposer:

    /* Compose the full CoverSheet envelope from the query's result HANDLEs.
       Handles (not the query object) keep this composer DB-free and decoupled,
       matching the sibling composers. */
    METHOD PUBLIC LONGCHAR Compose(INPUT pcPartNumber AS CHARACTER,
                                   INPUT phHeader      AS HANDLE,
                                   INPUT phStructure   AS HANDLE,
                                   INPUT phRoute       AS HANDLE,
                                   INPUT phComments    AS HANDLE):
        DEFINE VARIABLE oEnvelope    AS JsonObject NO-UNDO.
        DEFINE VARIABLE oStructComp  AS ProductStructureJsonComposer NO-UNDO.
        DEFINE VARIABLE oRouteComp   AS ProductRouteJsonComposer     NO-UNDO.
        DEFINE VARIABLE lcOut        AS LONGCHAR   NO-UNDO.

        oEnvelope   = NEW JsonObject().
        oStructComp = NEW ProductStructureJsonComposer().
        oRouteComp  = NEW ProductRouteJsonComposer().

        /* required top-level identity */
        JsonFormat:AddString(oEnvelope, "PartNumber":U, pcPartNumber).

        /* header object (empty/unknown members -> null) */
        oEnvelope:Add("Header":U, BuildHeader(INPUT phHeader)).

        /* reused arrays: canonical structure + full-shape route */
        oEnvelope:Add("Structure":U, oStructComp:ComposeArray(INPUT phStructure)).
        oEnvelope:Add("Route":U,     oRouteComp:ComposeArrayFull(INPUT phRoute)).

        /* comments as a plain string array */
        oEnvelope:Add("Comments":U, BuildComments(INPUT phComments)).

        oEnvelope:Write(OUTPUT lcOut).
        RETURN lcOut.
    END METHOD.

    /* The single header row -> a JsonObject with all CoverSheetHeader members. */
    METHOD PRIVATE JsonObject BuildHeader(INPUT phHeader AS HANDLE):
        DEFINE VARIABLE oHdr    AS JsonObject NO-UNDO.
        DEFINE VARIABLE hBuffer AS HANDLE     NO-UNDO.
        DEFINE VARIABLE hQuery  AS HANDLE     NO-UNDO.

        oHdr    = NEW JsonObject().
        hBuffer = phHeader:DEFAULT-BUFFER-HANDLE.

        CREATE QUERY hQuery.
        hQuery:SET-BUFFERS(hBuffer).
        hQuery:QUERY-PREPARE("FOR EACH " + hBuffer:NAME + " NO-LOCK":U).
        hQuery:QUERY-OPEN().
        hQuery:GET-FIRST().

        IF hBuffer:AVAILABLE THEN
        DO:
            AddHdr(oHdr, hBuffer, "ShipTo":U).
            AddHdr(oHdr, hBuffer, "ShipName":U).
            AddHdr(oHdr, hBuffer, "PartNumber":U).
            AddHdr(oHdr, hBuffer, "AltPartNumber":U).
            AddHdr(oHdr, hBuffer, "Revision":U).
            AddHdr(oHdr, hBuffer, "Description":U).
            AddHdr(oHdr, hBuffer, "Bom":U).
            AddHdr(oHdr, hBuffer, "CustItem":U).
            AddHdr(oHdr, hBuffer, "RouteCode":U).
            AddHdr(oHdr, hBuffer, "QtyPallet":U).
            AddHdr(oHdr, hBuffer, "Note1":U).  AddHdr(oHdr, hBuffer, "Note2":U).
            AddHdr(oHdr, hBuffer, "Note3":U).  AddHdr(oHdr, hBuffer, "Note4":U).
            AddHdr(oHdr, hBuffer, "Note5":U).  AddHdr(oHdr, hBuffer, "Note6":U).
            AddHdr(oHdr, hBuffer, "Note7":U).  AddHdr(oHdr, hBuffer, "Note8":U).
            AddHdr(oHdr, hBuffer, "Note9":U).  AddHdr(oHdr, hBuffer, "Note10":U).
        END.

        RETURN oHdr.

        FINALLY:
            IF VALID-HANDLE(hQuery) THEN
            DO:
                IF hQuery:IS-OPEN THEN hQuery:QUERY-CLOSE().
                DELETE OBJECT hQuery.
            END.
        END FINALLY.
    END METHOD.

    /* Add one header field (empty/unknown -> JSON null) by buffer-field name. */
    METHOD PRIVATE VOID AddHdr(INPUT poObj    AS JsonObject,
                               INPUT phBuffer  AS HANDLE,
                               INPUT pcField    AS CHARACTER):
        JsonFormat:AddStringOrNull(poObj, pcField,
            phBuffer:BUFFER-FIELD(pcField):BUFFER-VALUE).
        RETURN.
    END METHOD.

    /* Comments temp-table -> plain JSON string array (in SeqNo order). */
    METHOD PRIVATE JsonArray BuildComments(INPUT phComments AS HANDLE):
        DEFINE VARIABLE oArray  AS JsonArray NO-UNDO.
        DEFINE VARIABLE hBuffer AS HANDLE    NO-UNDO.
        DEFINE VARIABLE hQuery  AS HANDLE    NO-UNDO.

        oArray  = NEW JsonArray().
        hBuffer = phComments:DEFAULT-BUFFER-HANDLE.

        CREATE QUERY hQuery.
        hQuery:SET-BUFFERS(hBuffer).
        hQuery:QUERY-PREPARE("FOR EACH " + hBuffer:NAME + " NO-LOCK BY SeqNo":U).
        hQuery:QUERY-OPEN().

        hQuery:GET-FIRST().
        DO WHILE hBuffer:AVAILABLE:
            oArray:Add(STRING(hBuffer:BUFFER-FIELD("Comment":U):BUFFER-VALUE)).
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
