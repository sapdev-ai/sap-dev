REPORT zcc_t3_classic.
* CALL SCREEN 100.  <- full-line comment: MUST NOT be flagged
DATA lv_s TYPE string.
DATA lv_d TYPE string.
lv_s = 'CALL SCREEN 200'.   " string literal: MUST NOT be flagged
WRITE lv_s TO lv_d.          " WRITE ... TO is an assignment: MUST NOT be flagged
" WRITE / 'this is only a comment' -> MUST NOT be flagged
WRITE: / 'hello world'.      " classic list output: MUST hit WRITE_LIST_SLASH
CALL SCREEN 300.             " real dynpro call: MUST hit CALL_SCREEN
OPEN DATASET '/tmp/x' FOR INPUT IN TEXT MODE ENCODING DEFAULT.  " MUST hit OPEN_DATASET
SELECT * FROM bseg INTO TABLE @DATA(lt_seg).  " BSEG unreleased (has successor) -> UNRELEASED_API
