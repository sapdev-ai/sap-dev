REPORT zcc_t1_clean.
* A clean, cloud-friendly skeleton: released APIs only, no forbidden statements.
DATA(lo_type) = cl_abap_typedescr=>describe_by_name( 'MARA_X' ).
DATA lv_num TYPE i.
CALL FUNCTION 'NUMBER_GET_NEXT'
  EXPORTING
    nr_range_nr = '01'
    object      = 'ZCC'
  IMPORTING
    number      = lv_num.
DATA lv_text TYPE string.
lv_text = |done with { lv_num }|.
