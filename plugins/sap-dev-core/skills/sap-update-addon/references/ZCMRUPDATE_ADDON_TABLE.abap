*&---------------------------------------------------------------------*
*& Report ZCMRUPDATE_ADDON_TABLE
*& アドオンテーブル アップロード / ダウンロード ユーティリティ
*&---------------------------------------------------------------------*
REPORT zcmrupdate_addon_table.

*&---------------------------------------------------------------------*
*& Selection Screen
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
        lv_full      TYPE string.

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
    READ TABLE lt_filetable INTO DATA(ls_file) INDEX 1.
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
      ty_field_infos TYPE STANDARD TABLE OF ty_field_info WITH EMPTY KEY.

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
    mv_table = iv_table.
    TRANSLATE mv_table TO UPPER CASE.

    IF validate_addon_table( ) = abap_false.
      WRITE: / |エラー: { mv_table } はアドオンテーブルではありません（Y/Z始まりのみ対応）|.
      RETURN.
    ENDIF.

    IF get_field_catalog( ) = abap_false.
      WRITE: / |エラー: テーブル { mv_table } が見つかりません|.
      RETURN.
    ENDIF.

    IF iv_upload = abap_true.
      do_upload( iv_file ).
    ELSE.
      do_download( iv_file ).
    ENDIF.
  ENDMETHOD.

  METHOD validate_addon_table.
    DATA(lv_first) = mv_table(1).
    IF lv_first = 'Y' OR lv_first = 'Z'.
      rv_valid = abap_true.
    ELSE.
      rv_valid = abap_false.
    ENDIF.
  ENDMETHOD.

  METHOD get_field_catalog.
    DATA: lt_dfies TYPE TABLE OF dfies.

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
    LOOP AT lt_dfies INTO DATA(ls_dfies).
      APPEND VALUE ty_field_info(
        fieldname = ls_dfies-fieldname
        datatype  = ls_dfies-datatype
        leng      = ls_dfies-leng
        decimals  = ls_dfies-decimals
        keyflag   = ls_dfies-keyflag
        convexit  = ls_dfies-convexit
      ) TO mt_field_info.
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

    CALL FUNCTION 'GUI_UPLOAD'
      EXPORTING
        filename = iv_file
        filetype = 'ASC'
      TABLES
        data_tab = lt_raw
      EXCEPTIONS
        OTHERS   = 1.

    IF sy-subrc <> 0.
      WRITE: / |エラー: ファイル { iv_file } を読み込めません|.
      RETURN.
    ENDIF.

    IF lines( lt_raw ) < 2.
      WRITE: / 'エラー: ファイルにはヘッダー行とデータ行が必要です'.
      RETURN.
    ENDIF.

    READ TABLE lt_raw INTO DATA(lv_header) INDEX 1.
    SPLIT lv_header AT cl_abap_char_utilities=>horizontal_tab INTO TABLE lt_fields.

    DATA: lt_non_mandt TYPE TABLE OF ty_field_info.
    LOOP AT mt_field_info INTO DATA(ls_fi).
      IF ls_fi-datatype <> 'CLNT'.
        APPEND ls_fi TO lt_non_mandt.
      ENDIF.
    ENDLOOP.

    IF lines( lt_fields ) <> lines( lt_non_mandt ).
      WRITE: / |エラー: カラム数不一致 ファイル={ lines( lt_fields ) } テーブル={ lines( lt_non_mandt ) }|.
      WRITE: / '期待されるカラム:'.
      LOOP AT lt_non_mandt INTO ls_fi.
        WRITE: / | { ls_fi-fieldname }|.
      ENDLOOP.
      RETURN.
    ENDIF.

    DATA: lt_header_upper TYPE TABLE OF string.
    LOOP AT lt_fields INTO DATA(lv_fld).
      DATA(lv_upper) = lv_fld.
      TRANSLATE lv_upper TO UPPER CASE.
      CONDENSE lv_upper.
      APPEND lv_upper TO lt_header_upper.
    ENDLOOP.

    LOOP AT lt_non_mandt INTO ls_fi.
      READ TABLE lt_header_upper WITH KEY table_line = ls_fi-fieldname TRANSPORTING NO FIELDS.
      IF sy-subrc <> 0.
        WRITE: / |エラー: フィールド { ls_fi-fieldname } がヘッダーに見つかりません|.
        RETURN.
      ENDIF.
    ENDLOOP.

    DATA: lt_ordered_fields TYPE ty_field_infos.
    LOOP AT lt_header_upper INTO lv_upper.
      READ TABLE mt_field_info INTO ls_fi WITH KEY fieldname = lv_upper.
      IF sy-subrc = 0.
        APPEND ls_fi TO lt_ordered_fields.
      ENDIF.
    ENDLOOP.

    DATA: lo_struct TYPE REF TO cl_abap_structdescr,
          lr_wa     TYPE REF TO data.
    TRY.
        lo_struct ?= cl_abap_typedescr=>describe_by_name( mv_table ).
        CREATE DATA lr_wa TYPE HANDLE lo_struct.
      CATCH cx_sy_create_data_error.
        WRITE: / |エラー: テーブル { mv_table } の作業領域を作成できません|.
        RETURN.
    ENDTRY.

    FIELD-SYMBOLS: <fs_wa> TYPE any.
    ASSIGN lr_wa->* TO <fs_wa>.

    LOOP AT lt_raw INTO DATA(lv_raw) FROM 2.
      lv_line_num = sy-tabix.
      CLEAR: <fs_wa>.

      SPLIT lv_raw AT cl_abap_char_utilities=>horizontal_tab INTO TABLE lt_values.

      " ABAP SPLIT INTO TABLE strips trailing empty fields. Pad with empty
      " entries up to the expected column count so trailing-empty rows
      " (e.g. last currency/amount columns left blank) are accepted.
      WHILE lines( lt_values ) < lines( lt_ordered_fields ).
        APPEND '' TO lt_values.
      ENDWHILE.

      IF lines( lt_values ) <> lines( lt_ordered_fields ).
        lv_error = lv_error + 1.
        WRITE: / |行 { lv_line_num }: エラー - カラム数不一致 ファイル={ lines( lt_values ) } テーブル={ lines( lt_ordered_fields ) }|.
        CONTINUE.
      ENDIF.

      FIELD-SYMBOLS: <fs_field> TYPE any.
      READ TABLE mt_field_info WITH KEY datatype = 'CLNT' INTO DATA(ls_mandt_fi).
      IF sy-subrc = 0.
        ASSIGN COMPONENT ls_mandt_fi-fieldname OF STRUCTURE <fs_wa> TO <fs_field>.
        IF sy-subrc = 0.
          <fs_field> = sy-mandt.
        ENDIF.
      ENDIF.

      " Find currency value from CUKY field in same row
      DATA(lv_currency) = ||.
      LOOP AT lt_ordered_fields INTO DATA(ls_cuky) WHERE datatype = 'CUKY'.
        DATA(lv_cuky_idx) = sy-tabix.
        READ TABLE lt_values INTO DATA(lv_cuky_val) INDEX lv_cuky_idx.
        IF sy-subrc = 0.
          lv_currency = lv_cuky_val.
          CONDENSE lv_currency.
        ENDIF.
        EXIT.
      ENDLOOP.

      DATA(lv_line_ok) = abap_true.
      LOOP AT lt_ordered_fields INTO ls_fi.
        DATA(lv_idx) = sy-tabix.
        READ TABLE lt_values INTO DATA(lv_val) INDEX lv_idx.
        IF sy-subrc <> 0.
          lv_line_ok = abap_false.
          EXIT.
        ENDIF.

        ASSIGN COMPONENT ls_fi-fieldname OF STRUCTURE <fs_wa> TO <fs_field>.
        IF sy-subrc <> 0.
          lv_line_ok = abap_false.
          EXIT.
        ENDIF.

        DATA(lv_converted) = convert_to_internal( iv_value = lv_val is_field = ls_fi iv_currency = lv_currency ).
        <fs_field> = lv_converted.
      ENDLOOP.

      IF lv_line_ok = abap_false.
        lv_error = lv_error + 1.
        WRITE: / |行 { lv_line_num }: エラー - 値の変換に失敗|.
        CONTINUE.
      ENDIF.

      TRY.
          MODIFY (mv_table) FROM <fs_wa>.
          IF sy-subrc = 0.
            lv_success = lv_success + 1.
          ELSE.
            lv_error = lv_error + 1.
            WRITE: / |行 { lv_line_num }: エラー - MODIFY失敗 (sy-subrc={ sy-subrc })|.
          ENDIF.
        CATCH cx_sy_dynamic_osql_error INTO DATA(lx_sql).
          lv_error = lv_error + 1.
          WRITE: / |行 { lv_line_num }: エラー - { lx_sql->get_text( ) }|.
      ENDTRY.
    ENDLOOP.

    WRITE: / '========================================'.
    WRITE: / |アップロード完了: テーブル { mv_table }|.
    WRITE: / |成功: { lv_success }  エラー: { lv_error }|.
    WRITE: / '========================================'.
  ENDMETHOD.

  METHOD do_download.
    DATA: lt_output TYPE TABLE OF string.

    DATA: lt_non_mandt TYPE TABLE OF ty_field_info.
    LOOP AT mt_field_info INTO DATA(ls_fi).
      IF ls_fi-datatype <> 'CLNT'.
        APPEND ls_fi TO lt_non_mandt.
      ENDIF.
    ENDLOOP.

    DATA: lv_header TYPE string.
    LOOP AT lt_non_mandt INTO ls_fi.
      IF sy-tabix > 1.
        lv_header = lv_header && cl_abap_char_utilities=>horizontal_tab.
      ENDIF.
      lv_header = lv_header && ls_fi-fieldname.
    ENDLOOP.
    APPEND lv_header TO lt_output.

    DATA: lo_struct TYPE REF TO cl_abap_structdescr,
          lo_table  TYPE REF TO cl_abap_tabledescr,
          lr_table  TYPE REF TO data.
    TRY.
        lo_struct ?= cl_abap_typedescr=>describe_by_name( mv_table ).
        lo_table = cl_abap_tabledescr=>create( p_line_type = lo_struct ).
        CREATE DATA lr_table TYPE HANDLE lo_table.
      CATCH cx_sy_create_data_error.
        WRITE: / |エラー: テーブル { mv_table } の内部テーブルを作成できません|.
        RETURN.
    ENDTRY.

    FIELD-SYMBOLS: <fs_table> TYPE STANDARD TABLE.
    ASSIGN lr_table->* TO <fs_table>.

    TRY.
        SELECT * FROM (mv_table) INTO TABLE <fs_table>.
      CATCH cx_sy_dynamic_osql_error INTO DATA(lx_sql).
        WRITE: / |エラー: { lx_sql->get_text( ) }|.
        RETURN.
    ENDTRY.

    IF <fs_table> IS INITIAL.
      WRITE: / |テーブル { mv_table } にデータがありません|.
    ENDIF.

    FIELD-SYMBOLS: <fs_wa> TYPE any, <fs_field> TYPE any.
    DATA: lv_ext     TYPE string,
          lv_str_line TYPE string.
    LOOP AT <fs_table> ASSIGNING <fs_wa>.
      CLEAR lv_str_line.
      " Find currency value from CUKY field in same row
      DATA(lv_currency) = ||.
      LOOP AT lt_non_mandt INTO DATA(ls_cuky) WHERE datatype = 'CUKY'.
        ASSIGN COMPONENT ls_cuky-fieldname OF STRUCTURE <fs_wa> TO <fs_field>.
        IF sy-subrc = 0.
          lv_currency = <fs_field>.
          CONDENSE lv_currency.
        ENDIF.
        EXIT.
      ENDLOOP.
      LOOP AT lt_non_mandt INTO ls_fi.
        DATA(lv_tabix) = sy-tabix.
        ASSIGN COMPONENT ls_fi-fieldname OF STRUCTURE <fs_wa> TO <fs_field>.
        IF sy-subrc = 0.
          lv_ext = convert_to_external( iv_value = CONV string( <fs_field> ) is_field = ls_fi iv_currency = lv_currency ).
        ELSE.
          CLEAR lv_ext.
        ENDIF.
        IF lv_tabix > 1.
          lv_str_line = lv_str_line && cl_abap_char_utilities=>horizontal_tab.
        ENDIF.
        lv_str_line = lv_str_line && lv_ext.
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
      WRITE: / |ダウンロード完了: { iv_file }|.
      WRITE: / |テーブル: { mv_table }  件数: { lines( <fs_table> ) }|.
      WRITE: / '========================================'.
    ELSE.
      WRITE: / |エラー: ファイル { iv_file } への書き込みに失敗|.
    ENDIF.
  ENDMETHOD.

  METHOD convert_to_internal.
    DATA: lv_val    TYPE string,
          lv_fm     TYPE rs38l_fnam,
          lv_output TYPE string.

    lv_val = iv_value.
    CONDENSE lv_val.

    " 1. CURR → BAPI_CURRENCY_CONV_TO_INTERNAL
    IF is_field-datatype = 'CURR'.
      REPLACE ALL OCCURRENCES OF ',' IN lv_val WITH ''.
      DATA: lv_amt_in  TYPE bapicurr-bapicurr,
            lv_amt_out TYPE bapicurr-bapicurr,
            lv_curr    TYPE waers.
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
      DATA: lv_cunit_in TYPE meins.
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
      lv_fm = 'CONVERSION_EXIT_' && is_field-convexit && '_INPUT'.
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
        DATA(lv_len) = CONV i( is_field-leng ).
        IF strlen( lv_val ) < lv_len.
          DATA(lv_pad) = lv_len - strlen( lv_val ).
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

    lv_val = iv_value.
    CONDENSE lv_val.

    " 1. CURR → BAPI_CURRENCY_CONV_TO_EXTERNAL
    IF is_field-datatype = 'CURR'.
      DATA: lv_amt_ext TYPE bapicurr-bapicurr,
            lv_amt_int TYPE bapicurr-bapicurr,
            lv_curr_e  TYPE waers.
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
      DATA: lv_cunit_out TYPE meins.
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
      lv_fm = 'CONVERSION_EXIT_' && is_field-convexit && '_OUTPUT'.
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
  DATA(lo_util) = NEW lcl_table_util( ).
  lo_util->execute(
    iv_table  = p_table
    iv_file   = p_file
    iv_upload = rb_up
  ).
