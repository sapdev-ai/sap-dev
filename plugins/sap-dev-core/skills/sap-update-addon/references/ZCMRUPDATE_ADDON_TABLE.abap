*&---------------------------------------------------------------------*
*& Report ZCMRUPDATE_ADDON_TABLE
*& アドオンテーブル アップロード / ダウンロード ユーティリティ
*&---------------------------------------------------------------------*
*& CLASSIC-SYNTAX BOOTSTRAP UTILITY — DO NOT "MODERNIZE".
*&
*& Deployed by /sap-dev-init (Step 8) and used as the PROG-method
*& fallback by /sap-update-addon. It must activate on the LOWEST common
*& denominator release we support, which includes classic ECC 6.0 /
*& NetWeaver <= 7.40 systems. It is therefore written entirely in
*& classic, release-independent ABAP so a SINGLE source activates
*& cleanly on BOTH ECC 6.0 (~7.40) and S/4HANA 1909+.
*&
*& FORBIDDEN here (these do NOT activate on 7.40 — verified 2026-06-17 on
*& SID ER1 / ECC 6.0): inline DATA(...), VALUE #( ), NEW #( ), CONV #( ),
*& string templates |...{ }...|, the && concatenation operator, and
*& table types declared WITH EMPTY KEY. Use explicit DATA declarations,
*& CREATE OBJECT, CONCATENATE / WRITE, and WITH DEFAULT KEY instead.
*&
*& This is a deliberate, documented exception to the repo's
*& "modern ABAP" convention — see the "Classic-syntax exception" note in
*& sap-update-addon/SKILL.md before changing this file.
*&---------------------------------------------------------------------*
REPORT zcmrupdate_addon_table.

*&---------------------------------------------------------------------*
*& Selection Screen
*&  NOTE: gv_tit1 / gv_tit2 are intentionally NOT declared with DATA. The
*&  SELECTION-SCREEN ... WITH FRAME TITLE <name> clause IMPLICITLY declares
*&  the title variable (release-independent behaviour). Adding an explicit
*&  DATA declaration triggers "GV_TIT1 has already been declared" (verified
*&  on SID ER1 / ECC 6.0, 2026-06-17). They are populated in INITIALIZATION.
*&---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b_mode WITH FRAME TITLE gv_tit1.
  PARAMETERS: rb_up   RADIOBUTTON GROUP grp1 DEFAULT 'X',
              rb_down RADIOBUTTON GROUP grp1.
SELECTION-SCREEN END OF BLOCK b_mode.

SELECTION-SCREEN BEGIN OF BLOCK b_param WITH FRAME TITLE gv_tit2.
  PARAMETERS: p_table TYPE tabname OBLIGATORY,
              p_file  TYPE string LOWER CASE OBLIGATORY.
SELECTION-SCREEN END OF BLOCK b_param.

INITIALIZATION.
  gv_tit1 = '処理モード'.
  gv_tit2 = 'パラメータ'.

*&---------------------------------------------------------------------*
*& F4 Help for File Path
*&---------------------------------------------------------------------*
AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_file.
  DATA: lt_filetable TYPE filetable,
        lv_rc        TYPE i,
        lv_path      TYPE string,
        lv_full      TYPE string,
        ls_file      TYPE file_table.

  IF rb_up = abap_true.
    cl_gui_frontend_services=>file_open_dialog(
      EXPORTING
        window_title  = 'アップロードファイル選択'
        default_extension = 'txt'
        file_filter   = 'Text Files (*.txt)|*.txt|All Files (*.*)|*.*'
      CHANGING
        file_table = lt_filetable
        rc         = lv_rc
      EXCEPTIONS OTHERS = 1 ).
  ELSE.
    cl_gui_frontend_services=>file_save_dialog(
      EXPORTING
        window_title   = 'ダウンロードファイル選択'
        default_extension = 'txt'
        file_filter    = 'Text Files (*.txt)|*.txt|All Files (*.*)|*.*'
      CHANGING
        filename = p_file
        path     = lv_path
        fullpath = lv_full
      EXCEPTIONS OTHERS = 1 ).
    IF sy-subrc = 0 AND lv_full IS NOT INITIAL.
      p_file = lv_full.
    ENDIF.
    RETURN.
  ENDIF.

  IF sy-subrc = 0 AND lv_rc > 0.
    READ TABLE lt_filetable INTO ls_file INDEX 1.
    IF sy-subrc = 0.
      p_file = ls_file-filename.
    ENDIF.
  ENDIF.

*&---------------------------------------------------------------------*
*& Local Class Definition
*&---------------------------------------------------------------------*
CLASS lcl_table_util DEFINITION.
  PUBLIC SECTION.
    METHODS:
      execute
        IMPORTING
          iv_table TYPE tabname
          iv_file  TYPE string
          iv_upload TYPE abap_bool.

  PRIVATE SECTION.
    TYPES:
      BEGIN OF ty_field_info,
        fieldname TYPE fieldname,
        datatype  TYPE dynptype,
        leng      TYPE ddleng,
        decimals  TYPE decimals,
        keyflag   TYPE keyflag,
        convexit  TYPE convexit,
      END OF ty_field_info,
      ty_field_infos TYPE STANDARD TABLE OF ty_field_info WITH DEFAULT KEY.

    DATA:
      mv_table      TYPE tabname,
      mt_field_info TYPE ty_field_infos.

    METHODS:
      validate_addon_table
        RETURNING VALUE(rv_valid) TYPE abap_bool,
      get_field_catalog
        RETURNING VALUE(rv_ok) TYPE abap_bool,
      do_upload
        IMPORTING iv_file TYPE string,
      do_download
        IMPORTING iv_file TYPE string,
      convert_to_internal
        IMPORTING
          iv_value    TYPE string
          is_field    TYPE ty_field_info
          iv_currency TYPE string OPTIONAL
        RETURNING
          VALUE(rv_value) TYPE string,
      convert_to_external
        IMPORTING
          iv_value    TYPE string
          is_field    TYPE ty_field_info
          iv_currency TYPE string OPTIONAL
        RETURNING
          VALUE(rv_value) TYPE string.
ENDCLASS.

CLASS lcl_table_util IMPLEMENTATION.

  METHOD execute.
    DATA: lv_msg TYPE string.

    mv_table = iv_table.
    TRANSLATE mv_table TO UPPER CASE.

    IF validate_addon_table( ) = abap_false.
      CONCATENATE 'エラー:' mv_table 'はアドオンテーブルではありません（Y/Z始まりのみ対応）'
        INTO lv_msg SEPARATED BY space.
      WRITE: / lv_msg.
      RETURN.
    ENDIF.

    IF get_field_catalog( ) = abap_false.
      CONCATENATE 'エラー: テーブル' mv_table 'が見つかりません'
        INTO lv_msg SEPARATED BY space.
      WRITE: / lv_msg.
      RETURN.
    ENDIF.

    IF iv_upload = abap_true.
      do_upload( iv_file ).
    ELSE.
      do_download( iv_file ).
    ENDIF.
  ENDMETHOD.

  METHOD validate_addon_table.
    DATA lv_first(1) TYPE c.

    lv_first = mv_table(1).
    IF lv_first = 'Y' OR lv_first = 'Z'.
      rv_valid = abap_true.
    ELSE.
      rv_valid = abap_false.
    ENDIF.
  ENDMETHOD.

  METHOD get_field_catalog.
    DATA: lt_dfies      TYPE TABLE OF dfies,
          ls_dfies      TYPE dfies,
          ls_field_info TYPE ty_field_info.

    CALL FUNCTION 'DDIF_FIELDINFO_GET'
      EXPORTING
        tabname   = mv_table
      TABLES
        dfies_tab = lt_dfies
      EXCEPTIONS
        not_found = 1
        OTHERS    = 2.

    IF sy-subrc <> 0 OR lt_dfies IS INITIAL.
      rv_ok = abap_false.
      RETURN.
    ENDIF.

    CLEAR mt_field_info.
    LOOP AT lt_dfies INTO ls_dfies.
      CLEAR ls_field_info.
      ls_field_info-fieldname = ls_dfies-fieldname.
      ls_field_info-datatype  = ls_dfies-datatype.
      ls_field_info-leng      = ls_dfies-leng.
      ls_field_info-decimals  = ls_dfies-decimals.
      ls_field_info-keyflag   = ls_dfies-keyflag.
      ls_field_info-convexit  = ls_dfies-convexit.
      APPEND ls_field_info TO mt_field_info.
    ENDLOOP.

    rv_ok = abap_true.
  ENDMETHOD.

  METHOD do_upload.
    DATA: lt_raw      TYPE TABLE OF char2048,
          lt_fields   TYPE TABLE OF string,
          lt_values   TYPE TABLE OF string,
          lv_success  TYPE i VALUE 0,
          lv_error    TYPE i VALUE 0,
          lv_line_num TYPE i VALUE 0.

    DATA: lt_non_mandt      TYPE TABLE OF ty_field_info,
          lt_header_upper   TYPE TABLE OF string,
          lt_ordered_fields TYPE ty_field_infos.

    DATA: lv_header    TYPE char2048,
          lv_raw       TYPE char2048,
          lv_fld       TYPE string,
          lv_upper     TYPE string,
          lv_val       TYPE string,
          lv_cuky_val  TYPE string,
          lv_currency  TYPE string,
          lv_converted TYPE string,
          lv_cuky_idx  TYPE i,
          lv_idx       TYPE i,
          lv_line_ok   TYPE abap_bool.

    DATA: ls_fi       TYPE ty_field_info,
          ls_mandt_fi TYPE ty_field_info,
          ls_cuky     TYPE ty_field_info.

    DATA: lo_struct TYPE REF TO cl_abap_structdescr,
          lr_wa     TYPE REF TO data.

    DATA: lx_sql TYPE REF TO cx_sy_dynamic_osql_error.

    DATA: lv_msg   TYPE string,
          lv_n1    TYPE string,
          lv_n2    TYPE string,
          lv_n3    TYPE string,
          lv_etext TYPE string.

    FIELD-SYMBOLS: <fs_wa>    TYPE any,
                   <fs_field> TYPE any.

    CALL FUNCTION 'GUI_UPLOAD'
      EXPORTING
        filename = iv_file
        filetype = 'ASC'
      TABLES
        data_tab = lt_raw
      EXCEPTIONS
        OTHERS   = 1.

    IF sy-subrc <> 0.
      CONCATENATE 'エラー: ファイル' iv_file 'を読み込めません'
        INTO lv_msg SEPARATED BY space.
      WRITE: / lv_msg.
      RETURN.
    ENDIF.

    IF lines( lt_raw ) < 2.
      WRITE: / 'エラー: ファイルにはヘッダー行とデータ行が必要です'.
      RETURN.
    ENDIF.

    READ TABLE lt_raw INTO lv_header INDEX 1.
    SPLIT lv_header AT cl_abap_char_utilities=>horizontal_tab INTO TABLE lt_fields.

    LOOP AT mt_field_info INTO ls_fi.
      IF ls_fi-datatype <> 'CLNT'.
        APPEND ls_fi TO lt_non_mandt.
      ENDIF.
    ENDLOOP.

    IF lines( lt_fields ) <> lines( lt_non_mandt ).
      lv_n1 = lines( lt_fields ).
      CONDENSE lv_n1.
      lv_n2 = lines( lt_non_mandt ).
      CONDENSE lv_n2.
      CONCATENATE 'エラー: カラム数不一致 ファイル=' lv_n1 ' テーブル=' lv_n2 INTO lv_msg.
      WRITE: / lv_msg.
      WRITE: / '期待されるカラム:'.
      LOOP AT lt_non_mandt INTO ls_fi.
        WRITE: / ls_fi-fieldname.
      ENDLOOP.
      RETURN.
    ENDIF.

    LOOP AT lt_fields INTO lv_fld.
      lv_upper = lv_fld.
      TRANSLATE lv_upper TO UPPER CASE.
      CONDENSE lv_upper.
      APPEND lv_upper TO lt_header_upper.
    ENDLOOP.

    LOOP AT lt_non_mandt INTO ls_fi.
      READ TABLE lt_header_upper WITH KEY table_line = ls_fi-fieldname TRANSPORTING NO FIELDS.
      IF sy-subrc <> 0.
        CONCATENATE 'エラー: フィールド' ls_fi-fieldname 'がヘッダーに見つかりません'
          INTO lv_msg SEPARATED BY space.
        WRITE: / lv_msg.
        RETURN.
      ENDIF.
    ENDLOOP.

    LOOP AT lt_header_upper INTO lv_upper.
      READ TABLE mt_field_info INTO ls_fi WITH KEY fieldname = lv_upper.
      IF sy-subrc = 0.
        APPEND ls_fi TO lt_ordered_fields.
      ENDIF.
    ENDLOOP.

    TRY.
        lo_struct ?= cl_abap_typedescr=>describe_by_name( mv_table ).
        CREATE DATA lr_wa TYPE HANDLE lo_struct.
      CATCH cx_sy_create_data_error.
        CONCATENATE 'エラー: テーブル' mv_table 'の作業領域を作成できません'
          INTO lv_msg SEPARATED BY space.
        WRITE: / lv_msg.
        RETURN.
    ENDTRY.

    ASSIGN lr_wa->* TO <fs_wa>.

    LOOP AT lt_raw INTO lv_raw FROM 2.
      lv_line_num = sy-tabix.
      CLEAR <fs_wa>.

      SPLIT lv_raw AT cl_abap_char_utilities=>horizontal_tab INTO TABLE lt_values.

      " ABAP SPLIT INTO TABLE strips trailing empty fields. Pad with empty
      " entries up to the expected column count so trailing-empty rows
      " (e.g. last currency/amount columns left blank) are accepted.
      WHILE lines( lt_values ) < lines( lt_ordered_fields ).
        APPEND '' TO lt_values.
      ENDWHILE.

      IF lines( lt_values ) <> lines( lt_ordered_fields ).
        lv_error = lv_error + 1.
        lv_n1 = lv_line_num.
        CONDENSE lv_n1.
        lv_n2 = lines( lt_values ).
        CONDENSE lv_n2.
        lv_n3 = lines( lt_ordered_fields ).
        CONDENSE lv_n3.
        CONCATENATE '行' lv_n1 INTO lv_msg SEPARATED BY space.
        CONCATENATE lv_msg ': エラー - カラム数不一致 ファイル=' lv_n2 ' テーブル=' lv_n3 INTO lv_msg.
        WRITE: / lv_msg.
        CONTINUE.
      ENDIF.

      READ TABLE mt_field_info WITH KEY datatype = 'CLNT' INTO ls_mandt_fi.
      IF sy-subrc = 0.
        ASSIGN COMPONENT ls_mandt_fi-fieldname OF STRUCTURE <fs_wa> TO <fs_field>.
        IF sy-subrc = 0.
          <fs_field> = sy-mandt.
        ENDIF.
      ENDIF.

      " Find currency value from CUKY field in same row
      CLEAR lv_currency.
      LOOP AT lt_ordered_fields INTO ls_cuky WHERE datatype = 'CUKY'.
        lv_cuky_idx = sy-tabix.
        READ TABLE lt_values INTO lv_cuky_val INDEX lv_cuky_idx.
        IF sy-subrc = 0.
          lv_currency = lv_cuky_val.
          CONDENSE lv_currency.
        ENDIF.
        EXIT.
      ENDLOOP.

      lv_line_ok = abap_true.
      LOOP AT lt_ordered_fields INTO ls_fi.
        lv_idx = sy-tabix.
        READ TABLE lt_values INTO lv_val INDEX lv_idx.
        IF sy-subrc <> 0.
          lv_line_ok = abap_false.
          EXIT.
        ENDIF.

        ASSIGN COMPONENT ls_fi-fieldname OF STRUCTURE <fs_wa> TO <fs_field>.
        IF sy-subrc <> 0.
          lv_line_ok = abap_false.
          EXIT.
        ENDIF.

        lv_converted = convert_to_internal( iv_value = lv_val is_field = ls_fi iv_currency = lv_currency ).
        <fs_field> = lv_converted.
      ENDLOOP.

      IF lv_line_ok = abap_false.
        lv_error = lv_error + 1.
        lv_n1 = lv_line_num.
        CONDENSE lv_n1.
        CONCATENATE '行' lv_n1 INTO lv_msg SEPARATED BY space.
        CONCATENATE lv_msg ': エラー - 値の変換に失敗' INTO lv_msg.
        WRITE: / lv_msg.
        CONTINUE.
      ENDIF.

      TRY.
          MODIFY (mv_table) FROM <fs_wa>.
          IF sy-subrc = 0.
            lv_success = lv_success + 1.
          ELSE.
            lv_error = lv_error + 1.
            lv_n1 = lv_line_num.
            CONDENSE lv_n1.
            lv_n2 = sy-subrc.
            CONDENSE lv_n2.
            CONCATENATE '行' lv_n1 INTO lv_msg SEPARATED BY space.
            CONCATENATE lv_msg ': エラー - MODIFY失敗 (sy-subrc=' lv_n2 ')' INTO lv_msg.
            WRITE: / lv_msg.
          ENDIF.
        CATCH cx_sy_dynamic_osql_error INTO lx_sql.
          lv_error = lv_error + 1.
          lv_n1 = lv_line_num.
          CONDENSE lv_n1.
          lv_etext = lx_sql->get_text( ).
          CONCATENATE '行 ' lv_n1 ': エラー - ' lv_etext INTO lv_msg RESPECTING BLANKS.
          WRITE: / lv_msg.
      ENDTRY.
    ENDLOOP.

    WRITE: / '========================================'.
    CONCATENATE 'アップロード完了: テーブル' mv_table INTO lv_msg SEPARATED BY space.
    WRITE: / lv_msg.
    lv_n1 = lv_success.
    CONDENSE lv_n1.
    lv_n2 = lv_error.
    CONDENSE lv_n2.
    CONCATENATE '成功: ' lv_n1 '  エラー: ' lv_n2 INTO lv_msg RESPECTING BLANKS.
    WRITE: / lv_msg.
    WRITE: / '========================================'.
  ENDMETHOD.

  METHOD do_download.
    DATA: lt_output    TYPE TABLE OF string,
          lt_non_mandt TYPE TABLE OF ty_field_info.

    DATA: ls_fi   TYPE ty_field_info,
          ls_cuky TYPE ty_field_info.

    DATA: lv_header   TYPE string,
          lv_ext      TYPE string,
          lv_str_line TYPE string,
          lv_currency TYPE string,
          lv_in       TYPE string,
          lv_tabix    TYPE i.

    DATA: lo_struct TYPE REF TO cl_abap_structdescr,
          lo_table  TYPE REF TO cl_abap_tabledescr,
          lr_table  TYPE REF TO data.

    DATA: lx_sql TYPE REF TO cx_sy_dynamic_osql_error.

    DATA: lv_msg   TYPE string,
          lv_n1    TYPE string,
          lv_tabs  TYPE string,
          lv_etext TYPE string.

    FIELD-SYMBOLS: <fs_table> TYPE STANDARD TABLE,
                   <fs_wa>    TYPE any,
                   <fs_field> TYPE any.

    LOOP AT mt_field_info INTO ls_fi.
      IF ls_fi-datatype <> 'CLNT'.
        APPEND ls_fi TO lt_non_mandt.
      ENDIF.
    ENDLOOP.

    LOOP AT lt_non_mandt INTO ls_fi.
      IF sy-tabix > 1.
        CONCATENATE lv_header cl_abap_char_utilities=>horizontal_tab INTO lv_header.
      ENDIF.
      CONCATENATE lv_header ls_fi-fieldname INTO lv_header.
    ENDLOOP.
    APPEND lv_header TO lt_output.

    TRY.
        lo_struct ?= cl_abap_typedescr=>describe_by_name( mv_table ).
        lo_table = cl_abap_tabledescr=>create( p_line_type = lo_struct ).
        CREATE DATA lr_table TYPE HANDLE lo_table.
      CATCH cx_sy_create_data_error.
        CONCATENATE 'エラー: テーブル' mv_table 'の内部テーブルを作成できません'
          INTO lv_msg SEPARATED BY space.
        WRITE: / lv_msg.
        RETURN.
    ENDTRY.

    ASSIGN lr_table->* TO <fs_table>.

    TRY.
        SELECT * FROM (mv_table) INTO TABLE <fs_table>.
      CATCH cx_sy_dynamic_osql_error INTO lx_sql.
        lv_etext = lx_sql->get_text( ).
        CONCATENATE 'エラー:' lv_etext INTO lv_msg SEPARATED BY space.
        WRITE: / lv_msg.
        RETURN.
    ENDTRY.

    IF <fs_table> IS INITIAL.
      CONCATENATE 'テーブル' mv_table 'にデータがありません'
        INTO lv_msg SEPARATED BY space.
      WRITE: / lv_msg.
    ENDIF.

    LOOP AT <fs_table> ASSIGNING <fs_wa>.
      CLEAR lv_str_line.
      " Find currency value from CUKY field in same row
      CLEAR lv_currency.
      LOOP AT lt_non_mandt INTO ls_cuky WHERE datatype = 'CUKY'.
        ASSIGN COMPONENT ls_cuky-fieldname OF STRUCTURE <fs_wa> TO <fs_field>.
        IF sy-subrc = 0.
          lv_currency = <fs_field>.
          CONDENSE lv_currency.
        ENDIF.
        EXIT.
      ENDLOOP.
      LOOP AT lt_non_mandt INTO ls_fi.
        lv_tabix = sy-tabix.
        ASSIGN COMPONENT ls_fi-fieldname OF STRUCTURE <fs_wa> TO <fs_field>.
        IF sy-subrc = 0.
          lv_in = <fs_field>.
          lv_ext = convert_to_external( iv_value = lv_in is_field = ls_fi iv_currency = lv_currency ).
        ELSE.
          CLEAR lv_ext.
        ENDIF.
        IF lv_tabix > 1.
          CONCATENATE lv_str_line cl_abap_char_utilities=>horizontal_tab INTO lv_str_line.
        ENDIF.
        CONCATENATE lv_str_line lv_ext INTO lv_str_line.
      ENDLOOP.
      APPEND lv_str_line TO lt_output.
    ENDLOOP.

    CALL FUNCTION 'GUI_DOWNLOAD'
      EXPORTING
        filename = iv_file
        filetype = 'ASC'
        codepage = '4110'
      TABLES
        data_tab = lt_output
      EXCEPTIONS
        OTHERS   = 1.

    IF sy-subrc = 0.
      WRITE: / '========================================'.
      CONCATENATE 'ダウンロード完了:' iv_file INTO lv_msg SEPARATED BY space.
      WRITE: / lv_msg.
      lv_tabs = mv_table.
      CONDENSE lv_tabs.
      lv_n1 = lines( <fs_table> ).
      CONDENSE lv_n1.
      CONCATENATE 'テーブル: ' lv_tabs '  件数: ' lv_n1 INTO lv_msg RESPECTING BLANKS.
      WRITE: / lv_msg.
      WRITE: / '========================================'.
    ELSE.
      CONCATENATE 'エラー: ファイル' iv_file 'への書き込みに失敗'
        INTO lv_msg SEPARATED BY space.
      WRITE: / lv_msg.
    ENDIF.
  ENDMETHOD.

  METHOD convert_to_internal.
    DATA: lv_val    TYPE string,
          lv_fm     TYPE rs38l_fnam,
          lv_output TYPE string.

    DATA: lv_amt_in  TYPE bapicurr-bapicurr,
          lv_amt_out TYPE bapicurr-bapicurr,
          lv_curr    TYPE waers.

    DATA: lv_cunit_in TYPE meins.

    DATA: lv_len TYPE i,
          lv_pad TYPE i.

    lv_val = iv_value.
    CONDENSE lv_val.

    " 1. CURR → BAPI_CURRENCY_CONV_TO_INTERNAL
    IF is_field-datatype = 'CURR'.
      REPLACE ALL OCCURRENCES OF ',' IN lv_val WITH ''.
      lv_curr = iv_currency.
      TRY.
          lv_amt_in = lv_val.
        CATCH cx_root.
          rv_value = lv_val.
          RETURN.
      ENDTRY.
      CALL FUNCTION 'BAPI_CURRENCY_CONV_TO_INTERNAL'
        EXPORTING
          amount_external       = lv_amt_in
          currency              = lv_curr
          max_number_of_digits  = 23
        IMPORTING
          amount_internal = lv_amt_out
        EXCEPTIONS
          OTHERS         = 1.
      IF sy-subrc = 0.
        rv_value = lv_amt_out.
      ELSE.
        rv_value = lv_val.
      ENDIF.
      CONDENSE rv_value.
      RETURN.
    ENDIF.

    " 2. CUNIT convexit → CONVERSION_EXIT_CUNIT_INPUT (requires LANGUAGE param)
    IF is_field-convexit = 'CUNIT'.
      CALL FUNCTION 'CONVERSION_EXIT_CUNIT_INPUT'
        EXPORTING
          input    = lv_val
          language = sy-langu
        IMPORTING
          output = lv_cunit_in
        EXCEPTIONS
          OTHERS = 1.
      IF sy-subrc = 0.
        rv_value = lv_cunit_in.
      ELSE.
        rv_value = lv_val.
      ENDIF.
      CONDENSE rv_value.
      RETURN.
    ENDIF.

    " 3. Other CONVEXIT → CONVERSION_EXIT_XXXX_INPUT (dynamic)
    IF is_field-convexit IS NOT INITIAL.
      CONCATENATE 'CONVERSION_EXIT_' is_field-convexit '_INPUT' INTO lv_fm.
      TRY.
          CALL FUNCTION lv_fm
            EXPORTING
              input  = lv_val
            IMPORTING
              output = lv_output
            EXCEPTIONS
              OTHERS = 1.
          IF sy-subrc = 0.
            rv_value = lv_output.
          ELSE.
            rv_value = lv_val.
          ENDIF.
        CATCH cx_sy_dyn_call_error.
          rv_value = lv_val.
      ENDTRY.
      CONDENSE rv_value.
      RETURN.
    ENDIF.

    " 4. Fallback
    CASE is_field-datatype.
      WHEN 'QUAN'.
        rv_value = lv_val.
      WHEN 'DEC'.
        REPLACE ALL OCCURRENCES OF ',' IN lv_val WITH ''.
        rv_value = lv_val.
      WHEN 'DATS'.
        REPLACE ALL OCCURRENCES OF '-' IN lv_val WITH ''.
        rv_value = lv_val.
      WHEN 'TIMS'.
        REPLACE ALL OCCURRENCES OF ':' IN lv_val WITH ''.
        rv_value = lv_val.
      WHEN 'NUMC'.
        lv_len = is_field-leng.
        IF strlen( lv_val ) < lv_len.
          lv_pad = lv_len - strlen( lv_val ).
          DO lv_pad TIMES.
            CONCATENATE '0' lv_val INTO lv_val.
          ENDDO.
        ENDIF.
        rv_value = lv_val.
      WHEN OTHERS.
        rv_value = lv_val.
    ENDCASE.
  ENDMETHOD.

  METHOD convert_to_external.
    DATA: lv_val    TYPE string,
          lv_fm     TYPE rs38l_fnam,
          lv_output TYPE string.

    DATA: lv_amt_ext TYPE bapicurr-bapicurr,
          lv_amt_int TYPE bapicurr-bapicurr,
          lv_curr_e  TYPE waers.

    DATA: lv_cunit_out TYPE meins.

    lv_val = iv_value.
    CONDENSE lv_val.

    " 1. CURR → BAPI_CURRENCY_CONV_TO_EXTERNAL
    IF is_field-datatype = 'CURR'.
      lv_curr_e = iv_currency.
      TRY.
          lv_amt_int = lv_val.
          CALL FUNCTION 'BAPI_CURRENCY_CONV_TO_EXTERNAL'
            EXPORTING
              amount_internal       = lv_amt_int
              currency              = lv_curr_e
              max_number_of_digits  = 23
            IMPORTING
              amount_external = lv_amt_ext
            EXCEPTIONS
              OTHERS   = 1.
          IF sy-subrc = 0.
            rv_value = lv_amt_ext.
          ELSE.
            rv_value = lv_val.
          ENDIF.
        CATCH cx_root.
          rv_value = lv_val.
      ENDTRY.
      CONDENSE rv_value.
      RETURN.
    ENDIF.

    " 2. CUNIT convexit → CONVERSION_EXIT_CUNIT_OUTPUT (requires LANGUAGE param)
    IF is_field-convexit = 'CUNIT'.
      CALL FUNCTION 'CONVERSION_EXIT_CUNIT_OUTPUT'
        EXPORTING
          input    = lv_val
          language = sy-langu
        IMPORTING
          output = lv_cunit_out
        EXCEPTIONS
          OTHERS = 1.
      IF sy-subrc = 0.
        rv_value = lv_cunit_out.
      ELSE.
        rv_value = lv_val.
      ENDIF.
      CONDENSE rv_value.
      RETURN.
    ENDIF.

    " 3. Other CONVEXIT → CONVERSION_EXIT_XXXX_OUTPUT (dynamic)
    IF is_field-convexit IS NOT INITIAL.
      CONCATENATE 'CONVERSION_EXIT_' is_field-convexit '_OUTPUT' INTO lv_fm.
      TRY.
          CALL FUNCTION lv_fm
            EXPORTING
              input  = lv_val
            IMPORTING
              output = lv_output
            EXCEPTIONS
              OTHERS = 1.
          IF sy-subrc = 0.
            rv_value = lv_output.
          ELSE.
            rv_value = lv_val.
          ENDIF.
        CATCH cx_sy_dyn_call_error.
          rv_value = lv_val.
      ENDTRY.
      CONDENSE rv_value.
      RETURN.
    ENDIF.

    " 4. Fallback
    rv_value = lv_val.
  ENDMETHOD.

ENDCLASS.

*&---------------------------------------------------------------------*
*& Main Processing
*&---------------------------------------------------------------------*
START-OF-SELECTION.
  DATA lo_util TYPE REF TO lcl_table_util.

  CREATE OBJECT lo_util.
  lo_util->execute(
    iv_table  = p_table
    iv_file   = p_file
    iv_upload = rb_up
  ).
