FUNCTION z_cds_ddl_install.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(IV_MODE) TYPE  STRING DEFAULT 'CREATE'
*"     VALUE(IV_DDLNAME) TYPE  DDLNAME
*"     VALUE(IV_SOURCE) TYPE  STRING OPTIONAL
*"     VALUE(IV_SOURCE_TYPE) TYPE  DDDDLSRCTYPE DEFAULT 'V'
*"     VALUE(IV_PACKAGE) TYPE  DEVCLASS DEFAULT '$TMP'
*"     VALUE(IV_TRANSPORT) TYPE  TRKORR OPTIONAL
*"     VALUE(IV_ACTIVATE) TYPE  FLAG DEFAULT 'X'
*"     VALUE(IV_PUT_STATE) TYPE  OBJSTATE DEFAULT 'N'
*"  EXPORTING
*"     VALUE(EV_RC) TYPE  SYSUBRC
*"     VALUE(EV_STATE) TYPE  STRING
*"     VALUE(EV_SQLVIEW) TYPE  VIEWNAME
*"     VALUE(EV_MESSAGE) TYPE  STRING
*"----------------------------------------------------------------------
*  ADT-free CDS DDL-source installer (Plan D13). Deployed as a KEEPER
*  utility (function group ZFGDEVAI) alongside Z_GENERIC_RFC_WRAPPER_TBL.
*  Hosts CL_DD_DDL_HANDLER_FACTORY locally so the stateful
*  IF_DD_DDL_HANDLER can be driven create -> save -> write_tadir ->
*  activate (and delete) in one RFC call. RFC-enabled so /sap-gen-cds
*  gets structured results with no ADT and no spool scraping.
*
*  NOTE on DELETE: the handler removes the DDL source + generated SQL
*  view but NOT the DDLS TADIR object-directory entry. /sap-gen-cds
*  clears that orphan afterwards via shared/scripts/sap_tadir_delete.ps1
*  (-Object DDLS -ObjName <name> -Force) -> TR_TADIR_INTERFACE.
*
*  PRID: mandatory on write_tadir/write_trkorr (no default), defaults
*  to -1 on save/activate/delete. Pass -1 for consistency.
  DATA: lo_ddl  TYPE REF TO if_dd_ddl_handler,
        ls_srcv TYPE ddddlsrcv,
        lv_rc   TYPE sysubrc.

  CLEAR: ev_rc, ev_state, ev_sqlview, ev_message.
  ev_rc    = 4.
  ev_state = 'INIT'.

  lo_ddl = cl_dd_ddl_handler_factory=>create( ).

  IF iv_mode = 'DELETE'.
    TRY.
        lo_ddl->delete( name = iv_ddlname ).
        COMMIT WORK AND WAIT.
        ev_rc      = 0.
        ev_state   = 'DELETED'.
        ev_message = |DDL source { iv_ddlname } deleted|.
      CATCH cx_dd_ddl_delete INTO DATA(lx_del).
        ev_rc      = 8.
        ev_state   = 'DELETE_FAILED'.
        ev_message = lx_del->get_text( ).
      CATCH cx_root INTO DATA(lx_rd).
        ev_rc      = 8.
        ev_state   = 'DELETE_FAILED'.
        ev_message = lx_rd->get_text( ).
    ENDTRY.
    RETURN.
  ENDIF.

* --- CREATE (default) ---
  IF iv_source IS INITIAL.
    ev_rc      = 4.
    ev_state   = 'FAILED'.
    ev_message = 'IV_SOURCE is required for CREATE'.
    RETURN.
  ENDIF.

  ls_srcv-ddlname     = iv_ddlname.
  ls_srcv-source      = iv_source.
  ls_srcv-source_type = iv_source_type.
  ls_srcv-ddlanguage  = sy-langu.
  ls_srcv-as4user     = sy-uname.

  TRY.
      lo_ddl->save( name         = iv_ddlname
                    put_state    = iv_put_state
                    ddddlsrcv_wa = ls_srcv ).

      lv_rc = lo_ddl->write_tadir( objectname  = iv_ddlname
                                   devclass    = iv_package
                                   set_genflag = abap_false
                                   set_edtflag = abap_true
                                   prid        = -1 ).

      IF iv_transport IS NOT INITIAL.
        lo_ddl->write_trkorr( trkorr     = iv_transport
                              objectname = iv_ddlname
                              prid       = -1 ).
      ENDIF.

      ev_state = 'CREATED'.

      IF iv_activate = abap_true.
        lo_ddl->activate( name = iv_ddlname ).
        ev_state = 'ACTIVATED'.
      ENDIF.

      " Surface the generated SQL view name for classic views (source_type 'V')
      " from the @AbapCatalog.sqlViewName annotation (EV_SQLVIEW was otherwise unset).
      IF iv_source_type = 'V'.
        FIND FIRST OCCURRENCE OF REGEX `sqlViewName:\s*'([^']+)'`
             IN iv_source IGNORING CASE SUBMATCHES ev_sqlview.
        TRANSLATE ev_sqlview TO UPPER CASE.
      ENDIF.

      COMMIT WORK AND WAIT.
      ev_rc      = 0.
      ev_message = |DDL { iv_ddlname } { ev_state } tadir_rc={ lv_rc }|.

    CATCH cx_dd_ddl_save INTO DATA(lx_sv).
      ev_rc      = 8.
      ev_state   = 'SAVE_FAILED'.
      ev_message = |SAVE: { lx_sv->get_text( ) }|.
    CATCH cx_dd_ddl_activate INTO DATA(lx_ac).
      ev_rc      = 8.
      ev_state   = 'ACTIVATE_FAILED'.
      ev_message = |ACTIVATE: { lx_ac->get_text( ) }|.
    CATCH cx_root INTO DATA(lx_ro).
      ev_rc      = 8.
      ev_state   = 'FAILED'.
      ev_message = lx_ro->get_text( ).
  ENDTRY.

ENDFUNCTION.
