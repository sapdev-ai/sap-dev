FUNCTION %%FM_NAME%%.
*"----------------------------------------------------------------------
*" Inbound IDoc processing FM - GOLDEN TEMPLATE for /sap-gen-idoc-handler.
*" The signature below is FIXED (WE57 requires it exactly); do not change it.
*"  IMPORTING  INPUT_METHOD  TYPE BDWFAP_PAR-INPUTMETHD
*"             MASS_PROCESSING TYPE BDWFAP_PAR-MASS_PROC
*"  EXPORTING  WORKFLOW_RESULT TYPE BDWFAP_PAR-RESULT
*"             APPLICATION_VARIABLE TYPE BDWFAP_PAR-APPL_VAR
*"             IN_UPDATE_TASK  TYPE BDWFAP_PAR-UPDATETASK
*"             CALL_TRANSACTION_DONE TYPE BDWFAP_PAR-CALLTRANS
*"  TABLES     IDOC_CONTRL     STRUCTURE EDIDC
*"             IDOC_DATA       STRUCTURE EDIDD
*"             IDOC_STATUS     STRUCTURE BDIDOCSTAT
*"             RETURN_VARIABLES STRUCTURE BDWFRETVAR
*"             SERIALIZATION_INFO STRUCTURE BDI_SER
*"  EXCEPTIONS WRONG_FUNCTION_CALLED
*"----------------------------------------------------------------------
* Generated for IDoc type %%IDOCTYPE%% / message type %%MESTYP%%.
* Protocol encoded once, correctly: per-DOCNUM packet loop (the classic
* mass-processing trap), typed segment decode, 53(ok)/51(error) status per
* IDoc, RETURN_VARIABLES, and BAL application-log hooks.

  DATA: lt_seg    TYPE STANDARD TABLE OF edidd,
        ls_status TYPE bdidocstat,
        lv_error  TYPE flag,
        lv_ok     TYPE i,
        lv_err    TYPE i,
        lv_log    TYPE balloghndl.

* --- application log (BAL): one log for the whole packet ----------------
  DATA ls_loghdr TYPE bal_s_log.
  ls_loghdr-object    = '%%BAL_OBJECT%%'.       " TODO(MANUAL): your BAL object / subobject (SLG0)
  ls_loghdr-subobject = '%%BAL_SUBOBJECT%%'.
  ls_loghdr-aluser    = sy-uname.
  CALL FUNCTION 'BAL_LOG_CREATE'
    EXPORTING  i_s_log = ls_loghdr
    IMPORTING  e_log_handle = lv_log
    EXCEPTIONS OTHERS = 0.

* --- process each IDoc in the packet (group IDOC_DATA by DOCNUM) --------
  LOOP AT idoc_contrl INTO DATA(ls_ctrl).
    CLEAR: lv_error.
    " collect this IDoc's data segments
    lt_seg = VALUE #( FOR ls_d IN idoc_data WHERE ( docnum = ls_ctrl-docnum ) ( ls_d ) ).

    " --- typed segment decode -------------------------------------------
    LOOP AT lt_seg INTO DATA(ls_seg).
      CASE ls_seg-segnam.
%%SEGMENT_CASES%%
*       one WHEN '<SEGMENTTYP>'. block per mapped segment:
*         DATA(ls_<seg>) = CORRESPONDING #( ls_seg-sdata ).   " move SDATA into the segment structure
*         ... map ls_<seg>-<field> -> the BAPI parameter (from the mapping spec) ...
        WHEN OTHERS.
          " unmapped segment - ignore (or TODO(MANUAL) if it carries needed data)
      ENDCASE.
    ENDLOOP.

    " --- call the target BAPI (from --bapi) -----------------------------
    DATA lt_return TYPE STANDARD TABLE OF bapiret2.
%%BAPI_CALL%%
*   CALL FUNCTION '%%BAPI_NAME%%'
*     EXPORTING ...   " filled from the mapped segment fields
*     TABLES    return = lt_return.

    " --- evaluate BAPIRET2 -> status 53 (ok) / 51 (error) ---------------
    LOOP AT lt_return INTO DATA(ls_ret) WHERE type CA 'EA'.
      lv_error = abap_true.
      CALL FUNCTION 'BAL_LOG_MSG_ADD'
        EXPORTING i_log_handle = lv_log
                  i_s_msg = VALUE bal_s_msg( msgty = ls_ret-type msgid = ls_ret-id
                                             msgno = ls_ret-number msgv1 = ls_ret-message_v1
                                             msgv2 = ls_ret-message_v2 msgv3 = ls_ret-message_v3
                                             msgv4 = ls_ret-message_v4 )
        EXCEPTIONS OTHERS = 0.
    ENDLOOP.

    CLEAR ls_status.
    ls_status-docnum = ls_ctrl-docnum.
    IF lv_error = abap_true.
      ls_status-status = '51'.               " application error
      READ TABLE lt_return INTO ls_ret WITH KEY type = 'E'.
      IF sy-subrc = 0.
        ls_status-msgid = ls_ret-id. ls_status-msgno = ls_ret-number.
        ls_status-msgv1 = ls_ret-message_v1. ls_status-msgv2 = ls_ret-message_v2.
        ls_status-msgv3 = ls_ret-message_v3. ls_status-msgv4 = ls_ret-message_v4.
      ENDIF.
      lv_err = lv_err + 1.
    ELSE.
      ls_status-status = '53'.               " application document posted
      ls_status-msgid = '%%MSG_CLASS%%'. ls_status-msgno = '%%MSG_OK_NO%%'.
      lv_ok = lv_ok + 1.
      IF mass_processing = space.
        in_update_task = abap_true.          " single processing: post in update task
      ENDIF.
    ENDIF.
    APPEND ls_status TO idoc_status.
  ENDLOOP.

* --- workflow result + return variables (the reprocessing contract) -----
  IF lv_err > 0.
    workflow_result = '99999'.               " at least one error
  ELSE.
    workflow_result = '0'.
  ENDIF.
  APPEND VALUE bdwfretvar( wf_param = 'Processed_IDOCs' doc_number = lv_ok )  TO return_variables.
  APPEND VALUE bdwfretvar( wf_param = 'Error_IDOCs'     doc_number = lv_err ) TO return_variables.

  CALL FUNCTION 'BAL_DB_SAVE'
    EXPORTING i_save_all = abap_true
    EXCEPTIONS OTHERS = 0.

ENDFUNCTION.
