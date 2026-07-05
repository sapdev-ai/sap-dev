FUNCTION Z_GENERIC_RFC_WRAPPER_TBL.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(IV_FUNCNAME) TYPE  RS38L_FNAM
*"  CHANGING
*"     VALUE(CT_PARAMS) TYPE  ZCMCT_RFC_PARAM
*"  EXCEPTIONS
*"      FM_NOT_FOUND
*"      DESERIALIZATION_FAILED
*"      DYNAMIC_CALL_FAILED
*"      SERIALIZATION_FAILED
*"----------------------------------------------------------------------
* Generic RFC wrapper for non-RFC-enabled function modules.
*
* PROCESSING TYPE: Remote-Enabled Module (TFDIR.FMODE='R'). This is
*   set via the SE37 Attributes tab, NOT in this source file — ABAP
*   FUNCTION...ENDFUNCTION syntax has no way to declare RFC-enabled.
*   /sap-dev-init Step 7b sets it via /sap-se37 change_attrs
*   PROCESSING_TYPE=REMOTE after the initial create. Without
*   Remote-Enabled the FM cannot be invoked from NCo 3.1 (calls fail
*   with FU_NOT_REMOTE_ENABLED) and the entire wrapper concept is
*   dead-on-arrival. Re-runs of /sap-dev-init verify FMODE and re-apply
*   if needed (idempotent).
*
* The FM keeps its "_TBL" suffix for backward compatibility with deployed
* customer systems. Semantically, CT_PARAMS is a CHANGING table-typed
* parameter (ZCMCT_RFC_PARAM = STANDARD TABLE OF ZCMST_RFC_PARAM). The
* PowerShell caller (sap_rfc_wrapper_fm.ps1) accesses it via
* `$fn.GetTable("CT_PARAMS")` — that API works identically for CHANGING
* table types and TABLES parameters on NCo 3.1, so the caller needs no
* changes.
*
* History (why this is CHANGING, not TABLES):
*   Earlier revisions declared this as `TABLES CT_PARAMS STRUCTURE
*   ZCMST_RFC_PARAM` because the classic 32-bit SAP.Functions COM control
*   (librfc32) used by legacy VBScript exposes table-typed parameters
*   ONLY through the TABLES collection — CHANGING-table-typed parameters
*   were opaque scalars and unusable from cscript. That constraint no
*   longer applies: every RFC call site in sap-dev now goes through SAP
*   NCo 3.1 (PowerShell) which handles CHANGING table types natively.
*   librfc32 is grep-confirmed unreferenced in the plugin.
*
*   The migration also permanently silences SAP's "TABLES parameters
*   are obsolete!" Function Builder status-bar warning. That warning is
*   a passive sbar message that SAP keeps painting whenever the Tables
*   tab is on screen; ENTER does NOT clear it (confirmed 2026-05-12 —
*   the user pressed ENTER repeatedly and the message stayed). The only
*   way to remove the warning is to drop the TABLES section, which this
*   migration does.
*
* Why chunked PVALUE (CHAR 1333 + PSEQ):
*   Classical RFC requires the TABLES structure to be FULLY FLAT — no
*   STRING/SSTRING/internal-table/reference components allowed. A scalar
*   CHAR component is also capped at 1333 by DDIC. Long asXML payloads are
*   therefore split across multiple rows that share the same PNAME and are
*   ordered by PSEQ (1-based). Output payloads are split the same way.
*
* CT_PARAMS row layout:
*   PNAME      = parameter name (uppercase). Must be identical across all
*                chunks of one parameter.
*   PSEQ       = chunk sequence (1-based). Chunks are reassembled in
*                ascending PSEQ order per PNAME.
*   PTYPE      = I/E/C/T  (Importing / Exporting / Changing / Tables)
*                Must be supplied on every row of a parameter.
*   PTYPENAME  = DDIC type name suitable for CREATE DATA TYPE (..).
*                Must be supplied on every row of a parameter.
*   PVALUE     = asXML payload chunk (CHAR 1333). Concatenated by PSEQ for
*                input parameters; on output the wrapper writes back chunks
*                of length 1333 (last chunk may be shorter, blank-padded).

  TYPES: BEGIN OF ty_meta,
           pname     TYPE zcmst_rfc_param-pname,
           ptype     TYPE zcmst_rfc_param-ptype,
           ptypename TYPE zcmst_rfc_param-ptypename,
           dref      TYPE REF TO data,
         END OF ty_meta.
  DATA: lt_meta      TYPE TABLE OF ty_meta,
        ls_meta      TYPE ty_meta,
        lt_pars      TYPE abap_func_parmbind_tab,
        lt_excs      TYPE abap_func_excpbind_tab,
        ls_par       TYPE abap_func_parmbind,
        ls_exc       TYPE abap_func_excpbind,
        lr_data      TYPE REF TO data,
        lv_funcname  TYPE rs38l_fnam,
        lv_check     TYPE rs38l_fnam,
        lv_xml       TYPE string,
        lv_chunk     TYPE string,
        lv_off       TYPE i,
        lv_len       TYPE i,
        lv_seq       TYPE i,
        lv_chunklen  TYPE i VALUE 1333.

  FIELD-SYMBOLS: <fs_data>  TYPE any,
                 <fs_param> TYPE zcmst_rfc_param,
                 <fs_meta>  TYPE ty_meta,
                 <fs_chunk> TYPE zcmst_rfc_param.

  lv_funcname = iv_funcname.
  TRANSLATE lv_funcname TO UPPER CASE.

  SELECT SINGLE funcname FROM tfdir
         INTO lv_check
         WHERE funcname = lv_funcname.    " unescaped host vars: 7.31-safe (@-escape is 7.40+)
  IF sy-subrc <> 0.
    RAISE fm_not_found.
  ENDIF.

* ---- Sort input by PNAME / PSEQ so chunks reassemble correctly ----
  SORT ct_params BY pname pseq.

* ---- Build per-parameter metadata + dynamic data refs + parm bindings ----
  LOOP AT ct_params ASSIGNING <fs_param>.
* New parameter: create data ref and reassemble payload from all chunks
    AT NEW pname.
      CLEAR ls_meta.
      ls_meta-pname     = <fs_param>-pname.
      ls_meta-ptype     = <fs_param>-ptype.
      ls_meta-ptypename = <fs_param>-ptypename.

      DATA: lv_tabname  TYPE tabname,
            lv_fldname  TYPE fieldname,
            lv_typename TYPE string,
            lv_dash     TYPE i,
            lo_struct   TYPE REF TO cl_abap_structdescr,
            lo_comp     TYPE REF TO cl_abap_datadescr,
            lv_create_ok TYPE abap_bool.

      lv_create_ok = abap_false.
      CLEAR lr_data.
      TRY.
          CREATE DATA lr_data TYPE (<fs_param>-ptypename).
          lv_create_ok = abap_true.
        CATCH cx_root.
          " Try fallback: split TABNAME-FIELDNAME and use RTTI
          lv_dash = 0.
          FIND '-' IN <fs_param>-ptypename MATCH OFFSET lv_dash.
          IF sy-subrc = 0 AND lv_dash > 0.
            lv_tabname = <fs_param>-ptypename(lv_dash).
            lv_fldname = <fs_param>-ptypename+lv_dash.
            SHIFT lv_fldname LEFT BY 1 PLACES.
            TRY.
                lv_typename = lv_tabname.    " avoid CONV (7.40+); string-assign is 7.31-safe
                lo_struct ?= cl_abap_typedescr=>describe_by_name( lv_typename ).
                lo_comp    = lo_struct->get_component_type( lv_fldname ).
                CREATE DATA lr_data TYPE HANDLE lo_comp.
                lv_create_ok = abap_true.
              CATCH cx_root.
                lv_create_ok = abap_false.
            ENDTRY.
          ENDIF.
      ENDTRY.

      IF lv_create_ok = abap_false.
        " For Importing/Changing/Tables with payload we MUST resolve type → fail loudly
        IF ( ls_meta-ptype = 'I' OR ls_meta-ptype = 'C' OR ls_meta-ptype = 'T' ).
          CLEAR lv_xml.
          LOOP AT ct_params ASSIGNING <fs_chunk>
                            WHERE pname = <fs_param>-pname.
            CONCATENATE lv_xml <fs_chunk>-pvalue INTO lv_xml RESPECTING BLANKS.
          ENDLOOP.
          IF lv_xml IS NOT INITIAL.
            RAISE deserialization_failed.
          ENDIF.
        ENDIF.
        " For Exporting (or empty input) just record meta with null dref so we skip later
        APPEND ls_meta TO lt_meta.
        CONTINUE.
      ENDIF.

      ls_meta-dref = lr_data.

      CLEAR lv_xml.
      LOOP AT ct_params ASSIGNING <fs_chunk>
                        WHERE pname = <fs_param>-pname.
        CONCATENATE lv_xml <fs_chunk>-pvalue INTO lv_xml RESPECTING BLANKS.
      ENDLOOP.

      IF ( ls_meta-ptype = 'I' OR ls_meta-ptype = 'C' OR ls_meta-ptype = 'T' )
         AND lv_xml IS NOT INITIAL.
        ASSIGN lr_data->* TO <fs_data>.
        TRY.
            CALL TRANSFORMATION id
                 SOURCE XML lv_xml
                 RESULT data = <fs_data>.
          CATCH cx_root.
            RAISE deserialization_failed.
        ENDTRY.
      ENDIF.

      CLEAR ls_par.
      ls_par-name = ls_meta-pname.
      CASE ls_meta-ptype.
        WHEN 'I'. ls_par-kind = abap_func_exporting.
        WHEN 'E'. ls_par-kind = abap_func_importing.
        WHEN 'C'. ls_par-kind = abap_func_changing.
        WHEN 'T'. ls_par-kind = abap_func_tables.
        WHEN OTHERS.
          APPEND ls_meta TO lt_meta.
          CONTINUE.
      ENDCASE.
      ls_par-value = lr_data.
      INSERT ls_par INTO TABLE lt_pars.

      APPEND ls_meta TO lt_meta.
    ENDAT.
  ENDLOOP.

* ---- Single OTHERS catch-all ----
  CLEAR ls_exc.
  ls_exc-name  = 'OTHERS'.
  ls_exc-value = 1.
  INSERT ls_exc INTO TABLE lt_excs.

  TRY.
      CALL FUNCTION lv_funcname
        PARAMETER-TABLE lt_pars
        EXCEPTION-TABLE lt_excs.
      IF sy-subrc <> 0.
        RAISE dynamic_call_failed.
      ENDIF.
    CATCH cx_root.
      RAISE dynamic_call_failed.
  ENDTRY.

* ---- Rebuild CT_PARAMS as one row per chunk for E/C/T parameters; ----
* ---- preserve one row per I parameter (PVALUE cleared)              ----
  REFRESH ct_params.
  LOOP AT lt_meta ASSIGNING <fs_meta>.

    IF <fs_meta>-dref IS NOT BOUND.
      " Type couldn't be resolved earlier; emit a placeholder row only
      APPEND INITIAL LINE TO ct_params ASSIGNING <fs_param>.
      <fs_param>-pname     = <fs_meta>-pname.
      <fs_param>-pseq      = 1.
      <fs_param>-ptype     = <fs_meta>-ptype.
      <fs_param>-ptypename = <fs_meta>-ptypename.
      CONTINUE.
    ENDIF.

    IF <fs_meta>-ptype = 'E' OR <fs_meta>-ptype = 'C' OR <fs_meta>-ptype = 'T'.
      ASSIGN <fs_meta>-dref->* TO <fs_data>.
      TRY.
          CLEAR lv_xml.
          CALL TRANSFORMATION id
               SOURCE data = <fs_data>
               RESULT XML lv_xml.
        CATCH cx_root.
          RAISE serialization_failed.
      ENDTRY.

      lv_len = strlen( lv_xml ).
      IF lv_len = 0.
        CLEAR <fs_param>.
        APPEND INITIAL LINE TO ct_params ASSIGNING <fs_param>.
        <fs_param>-pname     = <fs_meta>-pname.
        <fs_param>-pseq      = 1.
        <fs_param>-ptype     = <fs_meta>-ptype.
        <fs_param>-ptypename = <fs_meta>-ptypename.
      ELSE.
        lv_off = 0.
        lv_seq = 0.
        WHILE lv_off < lv_len.
          lv_seq = lv_seq + 1.
          IF lv_off + lv_chunklen <= lv_len.
            lv_chunk = lv_xml+lv_off(lv_chunklen).
          ELSE.
            lv_chunk = lv_xml+lv_off.
          ENDIF.
          APPEND INITIAL LINE TO ct_params ASSIGNING <fs_param>.
          <fs_param>-pname     = <fs_meta>-pname.
          <fs_param>-pseq      = lv_seq.
          <fs_param>-ptype     = <fs_meta>-ptype.
          <fs_param>-ptypename = <fs_meta>-ptypename.
          <fs_param>-pvalue    = lv_chunk.
          lv_off = lv_off + lv_chunklen.
        ENDWHILE.
      ENDIF.
    ELSE.
* Importing — keep a single placeholder row, no payload back
      APPEND INITIAL LINE TO ct_params ASSIGNING <fs_param>.
      <fs_param>-pname     = <fs_meta>-pname.
      <fs_param>-pseq      = 1.
      <fs_param>-ptype     = <fs_meta>-ptype.
      <fs_param>-ptypename = <fs_meta>-ptypename.
    ENDIF.

  ENDLOOP.

ENDFUNCTION.
