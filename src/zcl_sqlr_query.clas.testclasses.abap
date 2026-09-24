*"* use this source file for your ABAP unit test classes

" The name rule, tested without a database.
"
" Saving and loading are database work and were proven against real tables
" when the tool was built. What can be decided without one is what a query may be
" called, and that rule matters more than it looks: the name is how a
" background job asks for the statement, through a selection screen and a
" variant, so a name nobody can type there is a query nobody can schedule.
CLASS ltcl_query_name DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.

    METHODS assert_ok
      IMPORTING iv_name TYPE string.

    METHODS assert_refused
      IMPORTING iv_name TYPE string
                iv_code TYPE string.

    METHODS plain_name           FOR TESTING.
    METHODS digits_and_underscore FOR TESTING.
    METHODS lower_case_is_upper  FOR TESTING.
    METHODS surrounding_spaces   FOR TESTING.
    METHODS empty_name           FOR TESTING.
    METHODS only_spaces          FOR TESTING.
    METHODS too_long             FOR TESTING.
    METHODS a_space_inside       FOR TESTING.
    METHODS punctuation          FOR TESTING.

ENDCLASS.


CLASS ltcl_query_name IMPLEMENTATION.

  METHOD assert_ok.
    cl_abap_unit_assert=>assert_true(
      act = zcl_sqlr_query=>valid_name( iv_name )-ok
      msg = |{ iv_name } should be allowed as a name| ).
  ENDMETHOD.

  METHOD assert_refused.
    DATA(ls) = zcl_sqlr_query=>valid_name( iv_name ).
    cl_abap_unit_assert=>assert_false( act = ls-ok
                                       msg = |{ iv_name } should not be allowed| ).
    cl_abap_unit_assert=>assert_equals( exp = iv_code act = ls-diag-code
                                        msg = 'refused for the wrong reason' ).
    cl_abap_unit_assert=>assert_not_initial( act = ls-diag-fix msg = 'no "fix"' ).
  ENDMETHOD.


  METHOD plain_name.
    assert_ok( `ACTUALISATIONS` ).
  ENDMETHOD.

  METHOD digits_and_underscore.
    assert_ok( `ZA04_TICKETS_2026` ).
  ENDMETHOD.

  METHOD lower_case_is_upper.
    " A query is not two queries because somebody held shift.
    assert_ok( `za04_tickets` ).
    cl_abap_unit_assert=>assert_equals(
      exp = `ZA04_TICKETS`
      act = zcl_sqlr_query=>normalise( ` za04_tickets ` )
      msg = 'stored upper case and trimmed' ).
  ENDMETHOD.

  METHOD surrounding_spaces.
    assert_ok( `  DAILY_STOCK  ` ).
  ENDMETHOD.

  METHOD empty_name.
    assert_refused( iv_name = `` iv_code = `NO_NAME` ).
  ENDMETHOD.

  METHOD only_spaces.
    assert_refused( iv_name = `   ` iv_code = `NO_NAME` ).
  ENDMETHOD.

  METHOD too_long.
    assert_refused( iv_name = `THIS_NAME_IS_MUCH_TOO_LONG_FOR_THE_FIELD_IT_HAS_TO_FIT`
                    iv_code = `NAME_TOO_LONG` ).
  ENDMETHOD.

  METHOD a_space_inside.
    " Not tidiness: a variant cannot carry it.
    assert_refused( iv_name = `DAILY STOCK` iv_code = `NAME_NOT_ALLOWED` ).
  ENDMETHOD.

  METHOD punctuation.
    assert_refused( iv_name = `STOCK;DROP` iv_code = `NAME_NOT_ALLOWED` ).
  ENDMETHOD.

ENDCLASS.
