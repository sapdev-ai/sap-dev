REPORT zcc_dyn.
* No forbidden statement and no known-unreleased API, but a dynamic CALL FUNCTION
* the regex scanner cannot see through -> tier stays TIER_1 but blindspot=Y.
DATA lv_fm TYPE string.
lv_fm = 'SOME_FM'.
CALL FUNCTION lv_fm.
DATA lv_unknown TYPE string.
lv_unknown = cl_some_unlisted_class=>helper( ).
