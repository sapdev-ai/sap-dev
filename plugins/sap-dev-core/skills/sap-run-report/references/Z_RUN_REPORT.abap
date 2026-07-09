FUNCTION Z_RUN_REPORT.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(IV_PROGRAM) TYPE SYREPID
*"     VALUE(IV_VARIANT) TYPE RALDB_VARI OPTIONAL
*"     VALUE(IV_JOBNAME) TYPE BTCJOB OPTIONAL
*"     VALUE(IV_IMMED) TYPE CHAR1 DEFAULT 'X'
*"  EXPORTING
*"     VALUE(EV_JOBNAME) TYPE BTCJOB
*"     VALUE(EV_JOBCOUNT) TYPE BTCJOBCNT
*"     VALUE(EV_STATUS) TYPE CHAR20
*"----------------------------------------------------------------------
* Schedule an ABAP report as a background job (JOB_OPEN -> SUBMIT VIA JOB
* -> JOB_CLOSE). RFC-enabled so /sap-run-report can call it directly; the
* list output is routed to a spool request (default print params, no dialog)
* so the caller can capture it via TBTCP.LISTIDENT -> /sap-sp02.
* Written 7.31/ECC6-safe (no COND #() / inline declarations) so /sap-dev-init
* can deploy it on any dev release. Read-only TRDIR guard (no writes here).
  DATA lv_jobname  TYPE btcjob.
  DATA lv_jobcount TYPE btcjobcnt.
  DATA lv_dummy    TYPE trdir-name.
  DATA ls_params   TYPE pri_params.
  DATA lv_valid    TYPE c.

  CLEAR: ev_jobname, ev_jobcount, ev_status.

  " Report must exist -- SUBMIT of a missing program dumps the job at run time.
  SELECT SINGLE name FROM trdir INTO lv_dummy WHERE name = iv_program.
  IF sy-subrc <> 0.
    ev_status = 'PROG_NOT_FOUND'.
    RETURN.
  ENDIF.

  IF iv_jobname IS INITIAL.
    lv_jobname = iv_program.
  ELSE.
    lv_jobname = iv_jobname.
  ENDIF.

  CALL FUNCTION 'JOB_OPEN'
    EXPORTING
      jobname          = lv_jobname
    IMPORTING
      jobcount         = lv_jobcount
    EXCEPTIONS
      cant_create_job  = 1
      invalid_job_data = 2
      jobname_missing  = 3
      OTHERS           = 4.
  IF sy-subrc <> 0.
    ev_status = 'OPEN_FAILED'.
    RETURN.
  ENDIF.

  " Default spool parameters (no dialog) so the background list is captured.
  CALL FUNCTION 'GET_PRINT_PARAMETERS'
    EXPORTING
      no_dialog      = 'X'
    IMPORTING
      out_parameters = ls_params
      valid          = lv_valid
    EXCEPTIONS
      OTHERS         = 0.

  IF iv_variant IS NOT INITIAL.
    SUBMIT (iv_program) VIA JOB lv_jobname NUMBER lv_jobcount
           USING SELECTION-SET iv_variant
           TO SAP-SPOOL SPOOL PARAMETERS ls_params WITHOUT SPOOL DYNPRO
           AND RETURN.
  ELSE.
    SUBMIT (iv_program) VIA JOB lv_jobname NUMBER lv_jobcount
           TO SAP-SPOOL SPOOL PARAMETERS ls_params WITHOUT SPOOL DYNPRO
           AND RETURN.
  ENDIF.
  IF sy-subrc <> 0.
    ev_status = 'SUBMIT_FAILED'.
    RETURN.
  ENDIF.

  CALL FUNCTION 'JOB_CLOSE'
    EXPORTING
      jobcount             = lv_jobcount
      jobname              = lv_jobname
      strtimmed            = iv_immed
    EXCEPTIONS
      cant_start_immediate = 1
      invalid_startdate    = 2
      jobname_missing      = 3
      job_close_failed     = 4
      job_nosteps          = 5
      job_notex            = 6
      lock_failed          = 7
      OTHERS               = 8.
  IF sy-subrc <> 0.
    ev_status = 'CLOSE_FAILED'.
    RETURN.
  ENDIF.

  ev_jobname  = lv_jobname.
  ev_jobcount = lv_jobcount.
  ev_status   = 'SUBMITTED'.
ENDFUNCTION.
