REPORT zmmrmat100r01 MESSAGE-ID zmm.

* DELIBERATELY BROKEN (lint regression fixture).
* Models two generator regressions the lint must catch:
*   1. a literal MESSAGE bypassing the message class
*      (LITERAL_MESSAGE).
*   2. a CALL FUNCTION whose FM signature snapshot was
*      dropped, so under --fixture the run would silently
*      fall back to training knowledge (SNAPSHOT_INCOMPLETE)
*      -- the green-wash hole --fixture closes.
*      _fm_signatures.txt is intentionally absent.

DATA gs_head   TYPE bapimathead.
DATA gs_return TYPE bapiret2.

PARAMETERS p_matnr TYPE matnr OBLIGATORY.

START-OF-SELECTION.
  AUTHORITY-CHECK OBJECT 'M_MATE_MAR'
    ID 'ACTVT' FIELD '01'
    ID 'BEGRU' FIELD space.
  IF sy-subrc <> 0.
    MESSAGE 'Material not authorized' TYPE 'E'.
  ENDIF.
  CALL FUNCTION 'BAPI_MATERIAL_SAVEDATA'
    EXPORTING
      headdata = gs_head
    IMPORTING
      return   = gs_return.
