*"* use this source file for your ABAP unit test classes

" What a file has to get right before anyone can trust a number in it.
"
" These are the two failures that do not announce themselves. A trailing
" minus makes a spreadsheet treat a column of money as text, so the total
" at the bottom is wrong and nothing says so. An unquoted separator shifts
" every column after it on one row out of fifty thousand.
CLASS ltcl_csv DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.

    TYPES: BEGIN OF ty_row,
             name   TYPE string,
             qty    TYPE p LENGTH 9 DECIMALS 3,
             booked TYPE d,
             at     TYPE t,
             count  TYPE i,
           END OF ty_row.

    METHODS negative_sign_moves_in_front FOR TESTING.
    METHODS positive_is_left_alone       FOR TESTING.
    METHODS date_is_iso                  FOR TESTING.
    METHODS empty_date_is_empty          FOR TESTING.
    METHODS time_is_iso                  FOR TESTING.
    METHODS text_keeps_inner_spaces      FOR TESTING.

    METHODS plain_value_is_not_quoted    FOR TESTING.
    METHODS separator_forces_quotes      FOR TESTING.
    METHODS quote_is_doubled             FOR TESTING.
    METHODS line_break_forces_quotes     FOR TESTING.
    METHODS comma_is_safe_under_semicolon FOR TESTING.

    METHODS header_is_the_column_names   FOR TESTING.
    METHODS row_has_every_column         FOR TESTING.

ENDCLASS.


CLASS ltcl_csv IMPLEMENTATION.

  METHOD negative_sign_moves_in_front.
    DATA lv_amount TYPE p LENGTH 9 DECIMALS 2.
    lv_amount = '-1234.56'.
    cl_abap_unit_assert=>assert_equals(
      exp = `-1234.56`
      act = zcl_sqlr_csv=>text_of( lv_amount )
      msg = 'ABAP writes the sign last; no spreadsheet reads it that way' ).
  ENDMETHOD.

  METHOD positive_is_left_alone.
    DATA lv_amount TYPE p LENGTH 9 DECIMALS 2.
    lv_amount = '1234.56'.
    cl_abap_unit_assert=>assert_equals( exp = `1234.56`
                                        act = zcl_sqlr_csv=>text_of( lv_amount ) ).
  ENDMETHOD.

  METHOD date_is_iso.
    DATA lv_date TYPE d VALUE '20260923'.
    cl_abap_unit_assert=>assert_equals( exp = `2026-09-23`
                                        act = zcl_sqlr_csv=>text_of( lv_date ) ).
  ENDMETHOD.

  METHOD empty_date_is_empty.
    DATA lv_date TYPE d.
    cl_abap_unit_assert=>assert_initial(
      act = zcl_sqlr_csv=>text_of( lv_date )
      msg = 'an empty date is empty, not the year nought' ).
  ENDMETHOD.

  METHOD time_is_iso.
    DATA lv_time TYPE t VALUE '143007'.
    cl_abap_unit_assert=>assert_equals( exp = `14:30:07`
                                        act = zcl_sqlr_csv=>text_of( lv_time ) ).
  ENDMETHOD.

  METHOD text_keeps_inner_spaces.
    DATA lv_text TYPE c LENGTH 30 VALUE 'TWO  SPACES   INSIDE'.
    cl_abap_unit_assert=>assert_equals(
      exp = `TWO  SPACES   INSIDE`
      act = zcl_sqlr_csv=>text_of( lv_text )
      msg = 'the padding goes, the content does not' ).
  ENDMETHOD.


  METHOD plain_value_is_not_quoted.
    cl_abap_unit_assert=>assert_equals(
      exp = `ROTTERDAM`
      act = zcl_sqlr_csv=>quoted( iv_text = `ROTTERDAM` iv_separator = ';' ) ).
  ENDMETHOD.

  METHOD separator_forces_quotes.
    cl_abap_unit_assert=>assert_equals(
      exp = `"A;B"`
      act = zcl_sqlr_csv=>quoted( iv_text = `A;B` iv_separator = ';' ) ).
  ENDMETHOD.

  METHOD quote_is_doubled.
    cl_abap_unit_assert=>assert_equals(
      exp = `"say ""no"""`
      act = zcl_sqlr_csv=>quoted( iv_text = `say "no"` iv_separator = ';' ) ).
  ENDMETHOD.

  METHOD line_break_forces_quotes.
    DATA(lv_text) = |first{ cl_abap_char_utilities=>cr_lf }second|.
    DATA(lv_out)  = zcl_sqlr_csv=>quoted( iv_text = lv_text iv_separator = ';' ).
    cl_abap_unit_assert=>assert_char_cp(
      act = lv_out
      exp = `"*"`
      msg = 'a value with a line break in it has to be quoted' ).
  ENDMETHOD.

  METHOD comma_is_safe_under_semicolon.
    " Only the separator in use matters. A comma in a semicolon-separated
    " file is an ordinary character and quoting it would be noise.
    cl_abap_unit_assert=>assert_equals(
      exp = `AMSTERDAM, NL`
      act = zcl_sqlr_csv=>quoted( iv_text = `AMSTERDAM, NL` iv_separator = ';' ) ).
  ENDMETHOD.


  METHOD header_is_the_column_names.
    DATA ls_row TYPE ty_row.
    cl_abap_unit_assert=>assert_equals(
      exp = `NAME;QTY;BOOKED;AT;COUNT`
      act = zcl_sqlr_csv=>header_line( is_row = ls_row iv_separator = ';' ) ).
  ENDMETHOD.

  METHOD row_has_every_column.
    DATA ls_row TYPE ty_row.
    ls_row-name   = `A;B`.
    ls_row-qty    = '-12.500'.
    ls_row-booked = '20260923'.
    ls_row-at     = '080000'.
    ls_row-count  = 7.
    cl_abap_unit_assert=>assert_equals(
      exp = `"A;B";-12.500;2026-09-23;08:00:00;7`
      act = zcl_sqlr_csv=>row_line( is_row = ls_row iv_separator = ';' ) ).
  ENDMETHOD.

ENDCLASS.
