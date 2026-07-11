REPORT %%TEST_REPORT%%.
*"----------------------------------------------------------------------
*" Seeded ABAP Unit test for the generated inbound handler %%FM_NAME%%.
*" Builds a canned EDIDC/EDIDD packet from the mapping spec's sample_value
*" column and asserts the IDOC_STATUS outcome (53 ok / 51 error). This is
*" the shape /sap-run-abap-unit consumes (same Z<STEM>_TEST loop as gen-abap).
*"----------------------------------------------------------------------

CLASS ltc_handler DEFINITION FOR TESTING DURATION SHORT RISK LEVEL HARMLESS.
  PRIVATE SECTION.
    METHODS build_packet
      EXPORTING et_contrl TYPE STANDARD TABLE OF edidc
                et_data   TYPE STANDARD TABLE OF edidd.
    METHODS happy_path FOR TESTING.       " one valid IDoc -> status 53
    " METHODS error_path FOR TESTING.     " TODO(MANUAL): one invalid IDoc -> status 51
ENDCLASS.

CLASS ltc_handler IMPLEMENTATION.

  METHOD build_packet.
    " one IDoc header
    et_contrl = VALUE #( ( docnum = '0000000000000001' idoctp = '%%IDOCTYPE%%'
                           mestyp = '%%MESTYP%%' status = '64' ) ).
    " data segments seeded from the mapping spec sample_value column:
%%CANNED_SEGMENTS%%
*   et_data = VALUE #(
*     ( docnum = '0000000000000001' segnam = '<SEGMENTTYP>' sdata = '<sample SDATA string>' )
*     ... ).
  ENDMETHOD.

  METHOD happy_path.
    DATA: lt_contrl TYPE STANDARD TABLE OF edidc,
          lt_data   TYPE STANDARD TABLE OF edidd,
          lt_status TYPE STANDARD TABLE OF bdidocstat,
          lt_retvar TYPE STANDARD TABLE OF bdwfretvar,
          lt_ser    TYPE STANDARD TABLE OF bdi_ser,
          lv_result TYPE bdwfap_par-result,
          lv_applvar TYPE bdwfap_par-appl_var,
          lv_upd    TYPE bdwfap_par-updatetask,
          lv_ct     TYPE bdwfap_par-calltrans.

    build_packet( IMPORTING et_contrl = lt_contrl et_data = lt_data ).

    CALL FUNCTION '%%FM_NAME%%'
      EXPORTING  input_method = 'A' mass_processing = space
      IMPORTING  workflow_result = lv_result application_variable = lv_applvar
                 in_update_task = lv_upd call_transaction_done = lv_ct
      TABLES     idoc_contrl = lt_contrl idoc_data = lt_data
                 idoc_status = lt_status return_variables = lt_retvar
                 serialization_info = lt_ser.

    " assert: exactly one status record, status 53 (posted)
    cl_abap_unit_assert=>assert_equals( act = lines( lt_status ) exp = 1 msg = 'one status per IDoc' ).
    READ TABLE lt_status INTO DATA(ls_st) INDEX 1.
    cl_abap_unit_assert=>assert_equals( act = ls_st-status exp = '53'
      msg = 'happy path must post (status 53), not 51 - check the segment decode + BAPI mapping' ).
  ENDMETHOD.

ENDCLASS.
