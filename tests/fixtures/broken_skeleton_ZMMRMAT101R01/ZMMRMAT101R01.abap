REPORT zmmrmat101r01 MESSAGE-ID zmm.

* DELIBERATELY BROKEN (skeleton regression fixture).
* The .abap itself is contract-clean -- the regression is in the emitted
* MANIFEST siblings, which is exactly what skeleton-diff guards:
*   1. .deps.txt silently DROPS the MAKT standard table (dep miss)
*   2. .traceability.txt RE-MAPS "Validation #1" to lcl_main->build instead
*      of lcl_main->validate (trace-pair miss)
* case.json still encodes the correct, full skeleton, so the diff fails.

CLASS lcl_main DEFINITION.
  PUBLIC SECTION.
    METHODS validate.
    METHODS build.
    METHODS execute.
ENDCLASS.

DATA gs_head TYPE bapimathead.

PARAMETERS p_matnr TYPE matnr OBLIGATORY.

START-OF-SELECTION.
  NEW lcl_main( )->execute( ).

CLASS lcl_main IMPLEMENTATION.
  METHOD validate.
  ENDMETHOD.
  METHOD build.
  ENDMETHOD.
  METHOD execute.
    CALL FUNCTION 'BAPI_MATERIAL_SAVEDATA'
      EXPORTING
        headdata = gs_head.
  ENDMETHOD.
ENDCLASS.
