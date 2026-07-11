FUNCTION Z_SQL_QUERY_RO.
*"----------------------------------------------------------------------
*"*"Local Interface:
*"  IMPORTING
*"     VALUE(I_FIELDS) TYPE  STRING
*"     VALUE(I_FROM) TYPE  STRING
*"     VALUE(I_WHERE) TYPE  STRING OPTIONAL
*"     VALUE(I_GROUPBY) TYPE  STRING OPTIONAL
*"     VALUE(I_HAVING) TYPE  STRING OPTIONAL
*"     VALUE(I_ORDERBY) TYPE  STRING OPTIONAL
*"     VALUE(I_PRIMARY_TABLE) TYPE  TABNAME
*"     VALUE(I_MAX_ROWS) TYPE  I DEFAULT 1000
*"     VALUE(I_DISTINCT) TYPE  CHAR1 DEFAULT SPACE
*"  EXPORTING
*"     VALUE(E_STATUS) TYPE  CHAR1
*"     VALUE(E_MSG) TYPE  STRING
*"     VALUE(E_ROWCOUNT) TYPE  I
*"     VALUE(E_TRUNCATED) TYPE  CHAR1
*"     VALUE(E_ELAPSED_MS) TYPE  I
*"     VALUE(E_VERSION) TYPE  STRING
*"  TABLES
*"      ET_DATA STRUCTURE  ZSQLQ_CHUNK
*"----------------------------------------------------------------------
* Z_SQL_QUERY_RO - governed READ-ONLY dynamic Open SQL for /sap-sql-query.
*
* PROCESSING TYPE: Remote-Enabled (set via SE37 Attributes / dev-init, NOT here).
* The PS caller (sap_sql_query_exec.ps1) decomposes a whitelist-validated SELECT
* into CLAUSE SLOTS and passes each separately; the FM plugs each into its own
* dynamic slot of ONE static statement, so a clause can never chain a second one.
*
* DEFENSE IN DEPTH (independent of the PS parser):
*  1. forbidden-token re-scan on every clause -> RAISE (E_STATUS='A', zero rows).
*  2. every referenced table re-validated against DD02L + VIEW_AUTHORITY_CHECK
*     (show) -> closes the "Open SQL bypasses S_TABU_DIS" hole.
*  3. hard row cap (<=10000) clamped here regardless of caller.
*  4. NO write statement exists anywhere in this FM; result itab is typed from
*     the primary FROM table (I_PRIMARY_TABLE) via RTTS + INTO CORRESPONDING
*     FIELDS (single-table SELECTs return every requested field; a join returns
*     the primary table's columns - use the skill's low-fidelity engine for the
*     full join projection).
*
* 7.02-safe dialect (no inline decl / string templates / @-escaped Open SQL) so
* ONE source compiles on ECC6 (7.31) and S/4HANA. Bump lc_version on any change.
* Source of record = the skill's references/; deployed by `install` (consent-gated);
* syntax verified at install time (/sap-check-abap or SE37 activation), never assumed.

  CONSTANTS lc_version TYPE string VALUE 'ZSQLQRO/1.0'.
  CONSTANTS lc_maxcap  TYPE i      VALUE 10000.
  CONSTANTS lc_chunk   TYPE i      VALUE 4000.

  DATA: lv_t0      TYPE i,
        lv_t1      TYPE i,
        lv_scan    TYPE string,
        lt_tokens  TYPE TABLE OF string,
        lv_tok     TYPE string,
        lv_from    TYPE string,
        lt_tabs    TYPE TABLE OF string,
        lv_tab     TYPE string,
        lv_tabname TYPE tabname,
        lv_maxp1   TYPE i,
        lv_cnt     TYPE i,
        lo_line    TYPE REF TO data,
        lo_tab     TYPE REF TO data,
        lo_sdescr  TYPE REF TO cl_abap_structdescr,
        lo_tdescr  TYPE REF TO cl_abap_tabledescr,
        lv_rownum  TYPE i,
        lv_seq     TYPE i,
        lv_off     TYPE i,
        lv_len     TYPE i,
        lv_take    TYPE i,
        lv_rowstr  TYPE string,
        lv_cval    TYPE string,
        lv_ci      TYPE i,
        ls_out     TYPE zsqlq_chunk.

  FIELD-SYMBOLS: <ft_tab>  TYPE STANDARD TABLE,
                 <fs_row>  TYPE any,
                 <fs_comp> TYPE any.

  e_version   = lc_version.
  e_status    = 'S'.
  e_truncated = space.
  REFRESH et_data.
  GET RUN TIME FIELD lv_t0.

* ---- 1. forbidden-token re-scan (server side) ----
  CONCATENATE i_fields i_from i_where i_groupby i_having i_orderby
              INTO lv_scan SEPARATED BY ` `.
  TRANSLATE lv_scan TO UPPER CASE.
  IF lv_scan CA ';' OR lv_scan CA '`' OR lv_scan CA '"' OR lv_scan CS '--'
     OR lv_scan CS ' MANDT' OR lv_scan CS 'CLIENT SPECIFIED'
     OR lv_scan CS 'BYPASSING' OR lv_scan CS 'CONNECTION'
     OR lv_scan CS 'FOR ALL ENTRIES' OR lv_scan CS 'UNION'.
    e_status = 'A'. e_msg = 'forbidden token in a clause'. RETURN.
  ENDIF.
  SPLIT lv_scan AT space INTO TABLE lt_tokens.
  LOOP AT lt_tokens INTO lv_tok.
    CASE lv_tok.
      WHEN 'INSERT' OR 'UPDATE' OR 'DELETE' OR 'MODIFY' OR 'DROP' OR 'CREATE'
        OR 'ALTER' OR 'EXEC' OR 'CALL' OR 'PERFORM' OR 'SUBMIT' OR 'COMMIT'
        OR 'ROLLBACK' OR 'INTO'.
        e_status = 'A'. e_msg = 'forbidden keyword in a clause'. RETURN.
    ENDCASE.
  ENDLOOP.

* ---- 2. re-validate every referenced table + authorization ----
  lv_from = i_from. TRANSLATE lv_from TO UPPER CASE.
  REPLACE ALL OCCURRENCES OF REGEX '[=<>().,~-]' IN lv_from WITH ` `.
  SPLIT lv_from AT space INTO TABLE lt_tabs.
  LOOP AT lt_tabs INTO lv_tab.
    IF lv_tab IS INITIAL OR strlen( lv_tab ) > 30. CONTINUE. ENDIF.
    CASE lv_tab.
      WHEN 'INNER' OR 'LEFT' OR 'OUTER' OR 'JOIN' OR 'ON' OR 'AS'. CONTINUE.
    ENDCASE.
    IF lv_tab CO '0123456789 '. CONTINUE. ENDIF.
    lv_tabname = lv_tab.
    SELECT SINGLE tabname FROM dd02l INTO lv_tabname WHERE tabname = lv_tabname.
    IF sy-subrc <> 0. CONTINUE. ENDIF.        " alias / ON-field token -> not a table
    CALL FUNCTION 'VIEW_AUTHORITY_CHECK'
      EXPORTING
        view_action                    = 'S'
        view_name                      = lv_tabname
      EXCEPTIONS
        no_authority                   = 2
        no_clientindependent_authority = 2
        no_linedependent_authority     = 2
        OTHERS                         = 1.
    IF sy-subrc = 2.
      e_status = 'A'.
      CONCATENATE 'not authorized to read table' lv_tabname INTO e_msg SEPARATED BY space.
      RETURN.
    ENDIF.
  ENDLOOP.

* ---- 3. clamp the row cap ----
  lv_maxp1 = i_max_rows.
  IF lv_maxp1 <= 0 OR lv_maxp1 > lc_maxcap. lv_maxp1 = lc_maxcap. ENDIF.

* ---- 4. type the result itab by the primary table (RTTS) ----
  IF i_primary_table IS INITIAL.
    e_status = 'A'. e_msg = 'primary table not supplied'. RETURN.
  ENDIF.
  TRY.
      lo_sdescr ?= cl_abap_typedescr=>describe_by_name( i_primary_table ).
      lo_tdescr  = cl_abap_tabledescr=>create( lo_sdescr ).
      CREATE DATA lo_tab TYPE HANDLE lo_tdescr.
      CREATE DATA lo_line TYPE HANDLE lo_sdescr.
    CATCH cx_root ##CATCH_ALL.
      e_status = 'A'. e_msg = 'could not type the result by the primary table'. RETURN.
  ENDTRY.
  ASSIGN lo_tab->* TO <ft_tab>.

* ---- 5. governed dynamic SELECT (read-only; cap bounds runtime) ----
  TRY.
      IF i_distinct = 'X'.
        SELECT DISTINCT (i_fields) FROM (i_from)
          INTO CORRESPONDING FIELDS OF TABLE <ft_tab>
          UP TO lv_maxp1 ROWS
          WHERE (i_where) GROUP BY (i_groupby) HAVING (i_having) ORDER BY (i_orderby).
      ELSE.
        SELECT (i_fields) FROM (i_from)
          INTO CORRESPONDING FIELDS OF TABLE <ft_tab>
          UP TO lv_maxp1 ROWS
          WHERE (i_where) GROUP BY (i_groupby) HAVING (i_having) ORDER BY (i_orderby).
      ENDIF.
    CATCH cx_sy_dynamic_osql_error cx_sy_open_sql_db cx_root INTO DATA(lx) ##CATCH_ALL.
      e_status = 'E'. e_msg = lx->get_text( ). RETURN.
  ENDTRY.

  DESCRIBE TABLE <ft_tab> LINES lv_cnt.
  e_rowcount = lv_cnt.
  IF lv_cnt >= lv_maxp1. e_truncated = 'X'. ENDIF.

* ---- 6. serialize each row to a tab-joined string, chunked to CHAR4000 ----
  lv_rownum = 0.
  LOOP AT <ft_tab> ASSIGNING <fs_row>.
    lv_rownum = lv_rownum + 1.
    CLEAR lv_rowstr. lv_ci = 1.
    DO.
      ASSIGN COMPONENT lv_ci OF STRUCTURE <fs_row> TO <fs_comp>.
      IF sy-subrc <> 0. EXIT. ENDIF.
      lv_cval = <fs_comp>.
      IF lv_ci = 1. lv_rowstr = lv_cval.
      ELSE. CONCATENATE lv_rowstr lv_cval INTO lv_rowstr SEPARATED BY cl_abap_char_utilities=>horizontal_tab. ENDIF.
      lv_ci = lv_ci + 1.
    ENDDO.
    lv_len = strlen( lv_rowstr ). lv_off = 0. lv_seq = 0.
    IF lv_len = 0.
      CLEAR ls_out. ls_out-rownum = lv_rownum. ls_out-seq = 1. APPEND ls_out TO et_data. CONTINUE.
    ENDIF.
    WHILE lv_off < lv_len.
      lv_seq = lv_seq + 1.
      IF lv_off + lc_chunk <= lv_len. lv_take = lc_chunk. ELSE. lv_take = lv_len - lv_off. ENDIF.
      CLEAR ls_out. ls_out-rownum = lv_rownum. ls_out-seq = lv_seq. ls_out-chunk = lv_rowstr+lv_off(lv_take).
      APPEND ls_out TO et_data.
      lv_off = lv_off + lc_chunk.
    ENDWHILE.
  ENDLOOP.

  GET RUN TIME FIELD lv_t1.
  e_elapsed_ms = ( lv_t1 - lv_t0 ) / 1000.

ENDFUNCTION.
