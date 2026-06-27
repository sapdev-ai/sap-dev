REPORT zmmrmat099r01 MESSAGE-ID zmm.

* Material master upload report (fixture).
* Contract-clean and spec-complete: every FM /
* AUTHORITY-CHECK / TEXT-NNN / MESSAGE used here
* has a concrete sibling row, so this case passes
* both --fixture lint and skeleton-diff.

TYPES: BEGIN OF ty_in,
         matnr TYPE matnr,
         mtart TYPE mtart,
       END OF ty_in.

CLASS lcl_main DEFINITION.
  PUBLIC SECTION.
    METHODS validate IMPORTING is_in TYPE ty_in
                     RETURNING VALUE(rv_ok) TYPE abap_bool.
    METHODS build    IMPORTING is_in TYPE ty_in.
    METHODS execute.
ENDCLASS.

DATA gv_count TYPE i.
DATA gs_head  TYPE bapimathead.
DATA gs_return TYPE bapiret2.

PARAMETERS p_matnr TYPE matnr OBLIGATORY.
PARAMETERS p_mtart TYPE mtart.

START-OF-SELECTION.
  WRITE / TEXT-001.
  AUTHORITY-CHECK OBJECT 'M_MATE_MAR'
    ID 'ACTVT' FIELD '01'
    ID 'BEGRU' FIELD space.
  IF sy-subrc <> 0.
    MESSAGE e001(zmm) WITH p_matnr.
  ENDIF.
  NEW lcl_main( )->execute( ).
  WRITE / TEXT-002.

CLASS lcl_main IMPLEMENTATION.
  METHOD validate.
    rv_ok = abap_true.
    IF is_in-matnr IS INITIAL.
      rv_ok = abap_false.
      MESSAGE e002(zmm) WITH is_in-matnr.
    ENDIF.
  ENDMETHOD.

  METHOD build.
    gs_head-material = is_in-matnr.
    gs_head-matl_type = is_in-mtart.
  ENDMETHOD.

  METHOD execute.
    gv_count = gv_count + 1.
    CALL FUNCTION 'BAPI_MATERIAL_SAVEDATA'
      EXPORTING
        headdata = gs_head
      IMPORTING
        return   = gs_return.
  ENDMETHOD.
ENDCLASS.
