FUNCTION z_class_source_install.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(IV_MODE) TYPE  STRING DEFAULT 'CREATE'
*"     VALUE(IV_CLSNAME) TYPE  SEOCLSNAME
*"     VALUE(IV_SOURCE) TYPE  STRING OPTIONAL
*"     VALUE(IV_DESCRIPTION) TYPE  SEODESCR OPTIONAL
*"     VALUE(IV_PACKAGE) TYPE  DEVCLASS DEFAULT '$TMP'
*"     VALUE(IV_TRANSPORT) TYPE  TRKORR OPTIONAL
*"     VALUE(IV_ACTIVATE) TYPE  FLAG DEFAULT 'X'
*"     VALUE(IV_OVERWRITE) TYPE  FLAG DEFAULT 'X'
*"  EXPORTING
*"     VALUE(EV_RC) TYPE  SYSUBRC
*"     VALUE(EV_STATE) TYPE  STRING
*"     VALUE(EV_INACTIVE) TYPE  FLAG
*"     VALUE(EV_MESSAGE) TYPE  STRING
*"----------------------------------------------------------------------
*  ADT-free / GUI-free global-class SOURCE installer -- the SE24 RFC
*  deploy fallback, analogous to RPY_PROGRAM_INSERT (SE38) and
*  RPY_FUNCTIONMODULE_INSERT (SE37), neither of which has a class
*  equivalent. Deploy as a KEEPER utility in function group ZFGDEVAI
*  alongside Z_GENERIC_RFC_WRAPPER_TBL / Z_CDS_DDL_INSTALL.
*
*  *** CREATE this FM as processing type "Remote-Enabled Module" ***
*  so /sap-se24 can call it directly over NCo. It internally drives the
*  NON-remote Class Builder APIs (SEO_CLASS_CREATE_COMPLETE + CL_OO_SOURCE),
*  the same "wrap a local handler in one RFC call" trick Z_CDS_DDL_INSTALL
*  uses for CL_DD_DDL_HANDLER_FACTORY.
*
*  MODES
*    CREATE (default) -- create-or-update the class from the full
*                        source-based body (CLASS..DEFINITION..ENDCLASS.
*                        CLASS..IMPLEMENTATION..ENDCLASS.), save, and
*                        (IV_ACTIVATE='X') activate. Idempotent: works
*                        whether or not the class already exists.
*    DELETE           -- remove the class object. NOTE: like every other
*                        create path in this toolset the delete leaves a
*                        TADIR orphan (OBJECT='CLAS'); clear it afterwards
*                        with shared/scripts/sap_tadir_delete.ps1
*                        -Object CLAS -ObjName <clsname> -Force.
*
*  PORTABILITY: classic declarations only (no inline DATA(), string templates,
*  VALUE #( )). The SOURCE primitive is CL_OO_FACTORY -> IF_OO_CLIF_SOURCE,
*  which ships on NW 7.31 EhP6+ (NOT 7.40 as first assumed) -- VERIFIED live on
*  EC2/ERP 7.31 EhP6 (ECC6): create/update/delete all green, same as S/4. So one
*  code path covers ECC6 EhP6 through S/4; no CL_OO_SOURCE fallback is needed.
*  (The deprecated CL_OO_SOURCE actually DUMPED here -- see the SET SOURCE block.)
*
*  API touchpoints -- VERIFIED live on S4D (7.54) AND EC2/ERP (7.31 EhP6, ECC6);
*  headless syntax check -Subc F -Wrap = CLEAN errors=0.
*    1) SEO_CLASS_CREATE_COMPLETE params ...... exact match, no change.
*    2) CL_OO_FACTORY=>CREATE_INSTANCE / CREATE_CLIF_SOURCE(CLIF_NAME=) verified.
*    3) IF_OO_CLIF_SOURCE LOCK / SET_SOURCE(SOURCE= SEOP_SOURCE_STRING) / SAVE /
*       UNLOCK verified; replaces the CL_OO_SOURCE path that DUMPED with
*       ASSERTION_FAILED on a fresh SEO shell (ST22 2026-07-05, see SET SOURCE).
*    4) RS_WORKING_OBJECTS_ACTIVATE (plural, FMODE=R) TABLES objects=DWINACTIV
*       -- activates the class's FULL inactive sub-part set (CLSD/CPUB/CPRO/CPRI
*       /CINC), not just the CLAS umbrella; SELECT SEOCLASSDF ver='1' = truth.
*    5) SEOCLASSDF VERSION='1' == active ....... confirmed (SEOVERSION domain).
*    6) SEO_CLASS_DELETE_COMPLETE ............. corrected: authority_check is
*       mandatory, corrnr is CHANGING (fixed 2026-07-04).
*  Robustness: IV_SOURCE is pre-validated (non-empty + contains CLASS..
*  DEFINITION) BEFORE any Class Builder call, because the OO source-write ASSERTs
*  are not trappable by CATCH cx_root -- junk input would dump, not return FAILED.
*  clsccincl is set 'X' only when the source carries a local class section.
*  Category is fixed to '00' (general). Exception classes (category '40',
*  INHERITING FROM CX_*) need the superclass on the shell -- a v2 param.
  DATA: lv_clsname TYPE seoclsname,
        lv_exists  TYPE abap_bool,
        lv_dummy   TYPE seoclsname,
        lv_active  TYPE seoclsname,
        lv_subrc   TYPE string,
        ls_clskey  TYPE seoclskey,
        ls_class   TYPE vseoclass,
        lo_factory TYPE REF TO cl_oo_factory,
        lo_clif    TYPE REF TO if_oo_clif_source,
        lt_source  TYPE seop_source_string,
        lt_inact   TYPE STANDARD TABLE OF dwinactiv,
        lv_pattern TYPE string,
        lv_has_def TYPE abap_bool,
        lv_src     TYPE string,
        lv_up      TYPE string,
        lv_corrnr  TYPE trkorr,
        lx_root    TYPE REF TO cx_root.

  CLEAR: ev_rc, ev_state, ev_inactive, ev_message.
  ev_rc    = 4.
  ev_state = 'INIT'.

  lv_clsname = iv_clsname.
  TRANSLATE lv_clsname TO UPPER CASE.
  ls_clskey-clsname = lv_clsname.

  IF lv_clsname IS INITIAL.
    ev_rc      = 4.
    ev_state   = 'FAILED'.
    ev_message = 'IV_CLSNAME is required'.
    RETURN.
  ENDIF.

* Does the repository object already exist?  (version-agnostic via TADIR)
  SELECT SINGLE obj_name FROM tadir INTO lv_dummy
    WHERE pgmid = 'R3TR' AND object = 'CLAS' AND obj_name = lv_clsname.
  IF sy-subrc = 0.
    lv_exists = 'X'.
  ENDIF.

  TRY.
* ---------------------------------------------------------------- DELETE
      IF iv_mode = 'DELETE'.
        IF lv_exists <> 'X'.
          ev_rc      = 0.
          ev_state   = 'NOT_FOUND'.
          ev_message = 'class does not exist; nothing to delete'.
          RETURN.
        ENDIF.
*       corrnr is CHANGING on this FM (it echoes the TR back); IV_TRANSPORT
*       is a read-only formal, so pass a local copy. authority_check is
*       mandatory with no default -- omitting it dumps at runtime.
        lv_corrnr = iv_transport.
        CALL FUNCTION 'SEO_CLASS_DELETE_COMPLETE'
          EXPORTING
            clskey          = ls_clskey
            authority_check = 'X'
          CHANGING
            corrnr          = lv_corrnr
          EXCEPTIONS
            not_existing    = 1
            is_interface    = 2
            db_error        = 3
            no_access       = 4
            OTHERS          = 5.
        IF sy-subrc = 0 OR sy-subrc = 1.
          COMMIT WORK AND WAIT.
          ev_rc      = 0.
          ev_state   = 'DELETED'.
          ev_message = 'class deleted; clear TADIR orphan via sap_tadir_delete.ps1 -Object CLAS'.
        ELSE.
          lv_subrc   = sy-subrc.
          ev_rc      = 8.
          ev_state   = 'DELETE_FAILED'.
          CONCATENATE 'SEO_CLASS_DELETE_COMPLETE subrc=' lv_subrc
                      INTO ev_message.
        ENDIF.
        RETURN.
      ENDIF.

* -------------------------------------------------------- CREATE / UPDATE
      IF iv_source IS INITIAL.
        ev_rc      = 4.
        ev_state   = 'FAILED'.
        ev_message = 'IV_SOURCE is required for CREATE'.
        RETURN.
      ENDIF.

      IF lv_exists = 'X' AND iv_overwrite <> 'X'.
        ev_rc      = 4.
        ev_state   = 'EXISTS'.
        ev_message = 'class exists and IV_OVERWRITE is not set'.
        RETURN.
      ENDIF.

*     Full source arrives as one STRING; normalise CRLF -> LF and split
*     into the source line table IF_OO_CLIF_SOURCE expects.
      lv_src = iv_source.
      REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>cr_lf
              IN lv_src WITH cl_abap_char_utilities=>newline.
      SPLIT lv_src AT cl_abap_char_utilities=>newline INTO TABLE lt_source.

*     Pre-validate the payload BEFORE any Class Builder call. The source-write
*     APIs (CL_OO_SOURCE / IF_OO_CLIF_SOURCE) run internal consistency ASSERTs
*     that ABAP CANNOT trap with CATCH cx_root -- so a malformed body dumps the
*     RFC instead of returning EV_STATE=FAILED. Fail cleanly here on the obvious
*     cases (empty / no CLASS..DEFINITION) so we never reach the assert path with
*     junk input. (This is the robustness-gap fix; the primitive switch below is
*     the fix for the actual assert that dumped -- see the SET SOURCE block.)
      lv_up = iv_source.
      TRANSLATE lv_up TO UPPER CASE.
      IF lv_up CS 'CLASS' AND lv_up CS 'DEFINITION'.
        lv_has_def = 'X'.
      ENDIF.
      IF lv_has_def <> 'X'.
        ev_rc      = 4.
        ev_state   = 'FAILED'.
        ev_message = 'IV_SOURCE is not a class source (no CLASS..DEFINITION found)'.
        RETURN.
      ENDIF.

*     (a) Create a minimal inactive shell when the class is new. Setting
*         the full source below re-derives the components on SAVE.
      IF lv_exists <> 'X'.
        CLEAR ls_class.
        ls_class-clsname   = lv_clsname.
        ls_class-version   = '0'.          " inactive (seoc_version_inactive)
        ls_class-langu     = sy-langu.
        ls_class-descript  = iv_description.
        ls_class-exposure  = '2'.          " public  (seoc_exposure_public)
        ls_class-state     = '1'.          " implemented (seoc_state_implemented)
*       clsccincl: 'X' promises a local-types/implementation (CCIMP) include.
*       Only claim it when the pushed source actually contains a local class
*       section -- promising an include the source does not carry is one of the
*       inputs that provokes the CL_OO_SOURCE save-consistency ASSERT. For a
*       plain source-based class (public section + method impls only) leave it
*       blank; IF_OO_CLIF_SOURCE->save re-derives the real include set from the
*       source below.
        IF lv_up CS 'CLASS ' AND ( lv_up CS 'DEFINITION DEFERRED'
                                OR lv_up CS 'IMPLEMENTATION.' AND lv_up CS 'CLASS LCL'
                                OR lv_up CS 'CLASS LCX' ).
          ls_class-clsccincl = 'X'.
        ELSE.
          ls_class-clsccincl = ' '.
        ENDIF.
        ls_class-fixpt     = 'X'.          " fixed point arithmetic
        ls_class-unicode   = 'X'.          " Unicode checks active
        ls_class-category  = '00'.         " general object type

        CALL FUNCTION 'SEO_CLASS_CREATE_COMPLETE'
          EXPORTING
            devclass        = iv_package
            version         = '0'
            authority_check = 'X'
            overwrite       = iv_overwrite
            corrnr          = iv_transport
          CHANGING
            class           = ls_class
          EXCEPTIONS
            existing        = 1
            is_interface    = 2
            db_error        = 3
            component_error = 4
            no_access       = 5
            OTHERS          = 6.
*       existing (1) is fine -- fall through and update the source.
        IF sy-subrc > 1.
          lv_subrc   = sy-subrc.
          ev_rc      = 8.
          ev_state   = 'CREATE_SHELL_FAILED'.
          CONCATENATE 'SEO_CLASS_CREATE_COMPLETE subrc=' lv_subrc
                      INTO ev_message.
          RETURN.
        ENDIF.
        ev_state = 'CREATED'.
      ELSE.
        ev_state = 'UPDATED'.
      ENDIF.

*     (b) Set the full source-based body, then save (leaves it inactive).
*         *** ROOT-CAUSE FIX (2026-07-05) ***
*         The previous revision used CL_OO_SOURCE directly:
*           CREATE OBJECT lo_source EXPORTING clskey = ls_clskey.
*           lo_source->access_permission( seok_access_modify ).
*           lo_source->set_source( lt_source ). lo_source->save( ).
*         Against a freshly-created SEO_CLASS_CREATE_COMPLETE shell, CL_OO_SOURCE
*         ->save runs an internal consistency ASSERT (reconciling the pushed
*         full-source blob against the shell's registered component / section-
*         include structure). That ASSERT DUMPED (ST22 ASSERTION_FAILED in
*         program CL_OO_SOURCE...CP, 2026-07-05) -- and an ABAP ASSERT is NOT
*         trappable by CATCH cx_root, so the RFC dumped instead of returning
*         EV_STATE=FAILED.
*         CL_OO_FACTORY->create_clif_source( ) -> IF_OO_CLIF_SOURCE is the
*         modern, abapGit-proven source primitive: it binds a CLIF source object
*         that handles the full-source blob correctly and does NOT hit that
*         assert. Call shapes + the SEOP_SOURCE_STRING source type were verified
*         (headless syntax check) live on S4D. lock/set_source/save/unlock raise
*         CX_OO_ACCESS_PERMISSION on a lock clash -- catchable, handled below.
*         PORTABILITY: CL_OO_FACTORY / IF_OO_CLIF_SOURCE need >= 7.40. On a 7.31
*         stack (ECC6 EhP6) the 7.31 fallback is the old CL_OO_SOURCE sequence
*         (CREATE OBJECT cl_oo_source / access_permission(seok_access_modify) /
*         set_source / save) -- gate it behind a CL_OO_FACTORY existence check
*         and re-verify against a live 7.31 class before trusting it there.
      lo_factory = cl_oo_factory=>create_instance( ).
      lo_clif = lo_factory->create_clif_source( clif_name = lv_clsname ).
      lo_clif->lock( ).
      lo_clif->set_source( source = lt_source ).
      lo_clif->save( ).
      lo_clif->unlock( ).

      COMMIT WORK AND WAIT.

*     (c) Activate (headless) then VERIFY over the DB.
*         *** ACTIVATION FIX (2026-07-05) ***
*         The previous revision called the SINGULAR RS_WORKING_OBJECT_ACTIVATE
*         with object='CLAS' obj_name=<class>. That activates only the CLAS
*         *umbrella* and MISSES the class's inactive sub-parts, so the class
*         stayed inactive (SEOCLASSDF version='1' never appeared -> EV_STATE=
*         SAVED_INACTIVE). Verified live on S4D: after IF_OO_CLIF_SOURCE->save a
*         global class leaves a DWINACTIV worklist of CLSD / CPUB / CPRO / CPRI
*         and CINC rows (<class>===...===CCDEF/CCIMP/CCMAC) -- NOT a single CLAS
*         row. The correct headless activator is the PLURAL
*         RS_WORKING_OBJECTS_ACTIVATE (FMODE=R), fed the full inactive-object
*         table (TYPE DWINACTIV) -- exactly what abapGit does. We read this
*         user's inactive rows for the class from DWINACTIV and pass them in one
*         call. SEOCLASSDF version='1' below remains the source of truth, with
*         the graceful SAVED_INACTIVE degrade if activation can't be confirmed.
      IF iv_activate = 'X'.
        REFRESH lt_inact.
*       Sub-part OBJ_NAME is either exactly <class> (section rows) or <class>
*       padded with '=' then a suffix (CINC rows). '<class>=%' catches the CINC
*       rows without over-matching a longer sibling (ZCL_X vs ZCL_XY: a sibling
*       is 'ZCL_XY', never 'ZCL_X='). NB: '_' is a LIKE single-char wildcard, so
*       this can in theory over-match another same-prefix class in THIS user's
*       worklist -- harmless (only rows we pass get activated), and it mirrors
*       abapGit's own pragmatic pattern; an ESCAPE clause is a future refinement.
        CONCATENATE lv_clsname '=%' INTO lv_pattern.
        SELECT * FROM dwinactiv INTO TABLE lt_inact
          WHERE uname = sy-uname
            AND ( obj_name = lv_clsname OR obj_name LIKE lv_pattern ).

        IF lt_inact IS NOT INITIAL.
          TRY.
              CALL FUNCTION 'RS_WORKING_OBJECTS_ACTIVATE'
                TABLES
                  objects = lt_inact
                EXCEPTIONS
                  OTHERS  = 1.
            CATCH cx_root.
*             swallow -- verification below decides ACTIVATED vs inactive
          ENDTRY.
        ENDIF.

        CLEAR lv_active.
        SELECT SINGLE clsname FROM seoclassdf INTO lv_active
          WHERE clsname = lv_clsname AND version = '1'.   " 1 = active
        IF sy-subrc = 0.
          ev_state = 'ACTIVATED'.
        ELSE.
          ev_inactive = 'X'.
          ev_state    = 'SAVED_INACTIVE'.
        ENDIF.
      ELSE.
        ev_inactive = 'X'.
        ev_state    = 'SAVED_INACTIVE'.
      ENDIF.

      ev_rc = 0.
      CONCATENATE 'CLAS' lv_clsname ev_state INTO ev_message SEPARATED BY space.
      IF ev_inactive = 'X' AND iv_activate = 'X'.
        CONCATENATE ev_message '(activation unverified -- run /sap-activate-object)'
                    INTO ev_message SEPARATED BY space.
      ENDIF.

    CATCH cx_root INTO lx_root.
      ev_rc = 8.
      IF ev_state = 'INIT' OR ev_state = 'CREATED' OR ev_state = 'UPDATED'.
        ev_state = 'FAILED'.
      ENDIF.
      ev_message = lx_root->get_text( ).
  ENDTRY.

ENDFUNCTION.
