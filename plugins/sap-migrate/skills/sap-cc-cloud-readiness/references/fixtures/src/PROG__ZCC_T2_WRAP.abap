REPORT zcc_t2_wrap.
* Only blocker is an unreleased API that the pack maps to a successor -> TIER_2.
DATA lo_conv TYPE REF TO cl_abap_conv_in_ce.
lo_conv = cl_abap_conv_in_ce=>create( ).
CALL FUNCTION 'BAPI_TRANSACTION_COMMIT'.
