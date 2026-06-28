/*------------------------------------------------------------------------
    File        : JsonFormat.cls
    Package     : ClearVue.Connector.Json
    Purpose     : Centralize the contract's wire-format rules so every member
                  added to a JsonObject/JsonArray is encoded identically.

    Wire-format standard (feasibility-11.6.md §3, CONTRIBUTING.md):
      - Decimals  -> JSON numbers, invariant '.' separator, NO thousands
                     separators, at the contract's per-field scale.
                     The session could be localized (-numsep/-numdec), so we
                     do NOT trust STRING(decimal); we add a real DECIMAL value
                     rounded to scale and let the JSON Object Model emit the
                     numeric token. (Numeric JSON tokens are invariant by spec;
                     this avoids any "1,5" risk from a localized STRING().)
      - Dates     -> ISO 8601 strings (yyyy-mm-dd) or JSON null when unknown.
      - Empty/?   character -> JSON null (e.g. empty notes -> null).

    These are *helpers*: the handler still decides which canonical field name
    each value goes under (full control, per the JSON Object Model decision).

    One responsibility: value encoding. No DB, no auth, no routing.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS ClearVue.Connector.Json.JsonFormat:

    /* Add a decimal at a fixed scale as a JSON number. Rounds half-up to
       piScale places; the JSON Object Model emits an invariant numeric token. */
    METHOD PUBLIC STATIC VOID AddNumber(INPUT poObj   AS JsonObject,
                                        INPUT pcName   AS CHARACTER,
                                        INPUT pdValue  AS DECIMAL,
                                        INPUT piScale  AS INTEGER):
        DEFINE VARIABLE dRounded AS DECIMAL NO-UNDO.

        IF pdValue = ? THEN
        DO:
            poObj:AddNull(pcName).
            RETURN.
        END.

        dRounded = ROUND(pdValue, piScale).
        poObj:Add(pcName, dRounded).
        RETURN.
    END METHOD.

    /* Add a character value, mapping empty/unknown to JSON null. */
    METHOD PUBLIC STATIC VOID AddStringOrNull(INPUT poObj  AS JsonObject,
                                              INPUT pcName  AS CHARACTER,
                                              INPUT pcValue AS CHARACTER):
        IF pcValue = ? OR pcValue = "":U THEN
            poObj:AddNull(pcName).
        ELSE
            poObj:Add(pcName, pcValue).
        RETURN.
    END METHOD.

    /* Add a non-null string (always present, never collapsed to null). Used
       for required fields like PartNumber. Emits "" rather than null when
       empty so a required field is never absent. */
    METHOD PUBLIC STATIC VOID AddString(INPUT poObj  AS JsonObject,
                                        INPUT pcName  AS CHARACTER,
                                        INPUT pcValue AS CHARACTER):
        poObj:Add(pcName, (IF pcValue = ? THEN "":U ELSE pcValue)).
        RETURN.
    END METHOD.

    /* Add an OE DATE as an ISO 8601 (yyyy-mm-dd) string, or JSON null. */
    METHOD PUBLIC STATIC VOID AddDateOrNull(INPUT poObj AS JsonObject,
                                            INPUT pcName AS CHARACTER,
                                            INPUT pdtValue AS DATE):
        IF pdtValue = ? THEN
            poObj:AddNull(pcName).
        ELSE
            poObj:Add(pcName,
                SUBSTITUTE("&1-&2-&3":U,
                    STRING(YEAR(pdtValue),  "9999":U),
                    STRING(MONTH(pdtValue), "99":U),
                    STRING(DAY(pdtValue),   "99":U))).
        RETURN.
    END METHOD.

END CLASS.
