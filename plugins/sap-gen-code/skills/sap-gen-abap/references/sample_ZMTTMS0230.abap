*&---------------------------------------------------------------------*
*& Program  : ZMTTMS0230
*& Title    : Depot Master Application
*& Service  : MTTMS0230
*& Generated: 2026-03-29
*& Document : Sample_Design.xlsx (Basic Design - Screen Service Design / Screen Item Definition)
*& System   : T: Integrated Master  Subsystem: TM: Integrated Master Management
*&---------------------------------------------------------------------*
PROGRAM zmttms0230 MESSAGE-ID msgs.

*&---------------------------------------------------------------------*
*& Constants — Combo Field Values
*&---------------------------------------------------------------------*
CONSTANTS:
  " Representative Depot Flag
  gc_daihyo_juzoku  TYPE c VALUE '0',   " 0: Subordinate Depot
  gc_daihyo_daihyo  TYPE c VALUE '1',   " 1: Representative Depot

  " Depot Category
  gc_depo_hon       TYPE c VALUE '0',   " 0: Main Depot
  gc_depo_koji      TYPE c VALUE '1',   " 1: Factory Depot
  gc_depo_kari      TYPE c VALUE '2',   " 2: Temporary Date Change Depot
  gc_depo_ll        TYPE c VALUE '3'.   " 3: LL Depot

*&---------------------------------------------------------------------*
*& Data Declarations
*&---------------------------------------------------------------------*
DATA:
  " ===== [ Application Category Display Section ] =====
  gv_shinsei_kubun     TYPE c LENGTH 10,  " Application Category (output label - New Registration/Change/End)

  " ===== [ Depot/Supplier Master Application Common Header ] =====
  gv_yuko_nen          TYPE c LENGTH 4,   " Effective Start Date (Year) (required mandatory)
  gv_yuko_tsuki        TYPE c LENGTH 2,   " Effective Start Date (Month) (required mandatory)
  gv_yuko_hi           TYPE c LENGTH 2,   " Effective Start Date (Day) (required mandatory)

  " ===== [ Standard Workplace Master Basic Information ] =====
  " Depot/Supplier Flag (used in conditional checks below - set elsewhere)
  gv_depo_shiiresaki_flg TYPE c LENGTH 1,

  gv_daihyo_hantei     TYPE c LENGTH 1,   " Representative Depot Flag (required conditional: required when Flag=1:Depot)
  gv_depo_kubun        TYPE c LENGTH 1,   " Depot Category (required conditional: required when Flag=1:Depot)
  gv_depo_name         TYPE c LENGTH 20,  " Depot Name (required conditional: required when Flag=1:Depot, full-width 10 chars)
  gv_depo_kana         TYPE c LENGTH 40,  " Depot Kana Name (required conditional: required when Flag=1:Depot, half-width 40 chars)
  gv_shiiresaki_name   TYPE c LENGTH 20,  " Supplier Name (required conditional: required when Flag=2:Supplier, full-width 10 chars)
  gv_shiiresaki_kana   TYPE c LENGTH 40.  " Supplier Kana Name (required conditional: required when Flag=2:Supplier, half-width 40 chars)

*&---------------------------------------------------------------------*
*& PBO — Process Before Output (screen 0100)
*&---------------------------------------------------------------------*
" In screen flow logic, call: MODULE pbo_0100 OUTPUT.
FORM pbo_0100.
  SET PF-STATUS 'MAIN'.
  SET TITLEBAR 'T0100'.

  " Default values (from Default Value column — all blank except operational date defaults)
  " For new registration: Set operational date as effective start date
  " (Operational date population logic goes here)
  CLEAR: gv_daihyo_hantei,
         gv_depo_kubun,
         gv_depo_name,
         gv_depo_kana,
         gv_shiiresaki_name,
         gv_shiiresaki_kana.
ENDFORM.

*&---------------------------------------------------------------------*
*& PAI — Process After Input (screen 0100)
*&---------------------------------------------------------------------*
" In screen flow logic, call: MODULE pai_0100 INPUT.
FORM pai_0100.
  PERFORM validate_fields.
ENDFORM.

*&---------------------------------------------------------------------*
*& Input Validation
*&---------------------------------------------------------------------*
FORM validate_fields.

  "-- Effective Start Date (Year) (required mandatory) --
  IF gv_yuko_nen IS INITIAL.
    MESSAGE e001(msgs).   " mandatory input error
    RETURN.
  ENDIF.
  " Single-field check: Input of year 1900 or earlier is an error → MSGS-ALTM00120
  IF gv_yuko_nen <= '1900'.
    MESSAGE e120(msgs) WITH 'ALTM00120'.
    RETURN.
  ENDIF.

  "-- Effective Start Date (Month) (required mandatory) --
  IF gv_yuko_tsuki IS INITIAL.
    MESSAGE e001(msgs).
    RETURN.
  ENDIF.

  "-- Effective Start Date (Day) (required mandatory) --
  IF gv_yuko_hi IS INITIAL.
    MESSAGE e001(msgs).
    RETURN.
  ENDIF.

  "-- Fields conditional on Depot/Supplier Flag = '1' (Depot) --
  IF gv_depo_shiiresaki_flg = '1'.

    "-- Representative Depot Flag (required conditional: required when Flag=1:Depot) --
    IF gv_daihyo_hantei IS INITIAL.
      MESSAGE e001(msgs).
      RETURN.
    ENDIF.
    " When 0: Subordinate Depot → Representative Depot Code mandatory, Corresponding Affiliation Location Code auto-set
    " When 1: Representative Depot → Representative Depot Code not input, Corresponding Affiliation Location Code mandatory
    " (Add Representative Depot Code / Affiliation Location Code cross-check here)

    "-- Depot Category (required conditional: required when Flag=1:Depot) --
    IF gv_depo_kubun IS INITIAL.
      MESSAGE e001(msgs).
      RETURN.
    ENDIF.

    "-- Depot Name (required conditional: required when Flag=1:Depot) --
    IF gv_depo_name IS INITIAL.
      MESSAGE e001(msgs).
      RETURN.
    ENDIF.
    " Existence check warning: Depot Master duplicate check (duplicate warning) → MSGS-WRTM00020
    " (Add depot master duplicate check here — issue warning, not error)
    " MESSAGE w020(msgs).   " MSGS-WRTM00020

    "-- Depot Kana Name (required conditional: required when Flag=1:Depot) --
    IF gv_depo_kana IS INITIAL.
      MESSAGE e001(msgs).
      RETURN.
    ENDIF.
    " Existence check warning: MSGS-WRTM00020 (same as above)

  ENDIF.

  "-- Fields conditional on Depot/Supplier Flag = '2' (Supplier) --
  IF gv_depo_shiiresaki_flg = '2'.

    "-- Supplier Name (required conditional: required when Flag=2:Supplier) --
    IF gv_shiiresaki_name IS INITIAL.
      MESSAGE e001(msgs).
      RETURN.
    ENDIF.
    " Existence check warning: Depot Master duplicate check (duplicate warning) → MSGS-WRTM00020

    "-- Supplier Kana Name (required conditional: required when Flag=2:Supplier) --
    IF gv_shiiresaki_kana IS INITIAL.
      MESSAGE e001(msgs).
      RETURN.
    ENDIF.
    " Existence check warning: MSGS-WRTM00020

  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& TODO: Implement the following stubs
*&---------------------------------------------------------------------*
" 1. Screen layout (Dynpro 0100) — define screen fields matching DATA declarations
" 2. GUI status 'MAIN' and title 'T0100' in SE41
" 3. Reference Copy logic (copy from reference record for New Registration)
" 4. Representative Depot Code / Corresponding Affiliation Location Code cross-field logic (Representative Depot Flag)
" 5. Depot Master Existence Check (duplicate warning MSGS-WRTM00020)
" 6. Database update logic (INSERT/UPDATE to depot master table)
