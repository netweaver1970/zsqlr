*"* use this source file for your ABAP unit test classes

" The matching rule, tested without a database.
"
" The entries are passed in, which is the whole reason check( ) takes them as
" an optional parameter: a rule about which tables may be read should not need
" a client, a table and test data to prove.
CLASS ltcl_allow DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.

    METHODS entries
      RETURNING VALUE(rt) TYPE zcl_sqlr_allow=>tt_entry.

    METHODS source
      IMPORTING iv_name   TYPE string
      RETURNING VALUE(rs) TYPE zcl_sqlr_guard=>ty_source.

    METHODS exact_name_allowed        FOR TESTING.
    METHODS exact_name_is_not_prefix  FOR TESTING.
    METHODS pattern_allowed           FOR TESTING.
    METHODS pattern_does_not_overrun  FOR TESTING.
    METHODS lower_case_is_the_same    FOR TESTING.
    METHODS inactive_entry_is_no      FOR TESTING.
    METHODS unknown_table_refused     FOR TESTING.
    METHODS every_source_is_checked   FOR TESTING.
    METHODS refusal_names_the_table   FOR TESTING.
    METHODS empty_list_allows_nothing FOR TESTING.

    " Whose entry counts. Per user since 24 September 2026.
    METHODS own_entry_allowed         FOR TESTING.
    METHODS other_users_entry_is_no   FOR TESTING.
    METHODS refusal_names_the_user    FOR TESTING.

    " The user rule.
    METHODS star_is_a_valid_user      FOR TESTING.
    METHODS empty_user_refused        FOR TESTING.

    " The entry rule, which the maintenance screen leans on entirely.
    METHODS plain_table_name_is_valid FOR TESTING.
    METHODS pattern_is_valid          FOR TESTING.
    METHODS namespaced_name_is_valid  FOR TESTING.
    METHODS empty_entry_refused       FOR TESTING.
    METHODS a_single_star_refused     FOR TESTING.
    METHODS punctuation_refused       FOR TESTING.
    METHODS a_space_inside_refused    FOR TESTING.

ENDCLASS.


CLASS ltcl_allow IMPLEMENTATION.

  METHOD entries.
    " Everybody's, apart from the last two: MARD is one named user's, so it
    " must allow that user and nobody else.
    rt = VALUE #(
      ( uname = '*'      entry = 'MARA'      active = abap_true )
      ( uname = '*'      entry = 'ZSALES_*'  active = abap_true )
      ( uname = '*'      entry = 'MARC'      active = abap_false )
      ( uname = 'ANALYST' entry = 'MARD'     active = abap_true ) ).
  ENDMETHOD.

  METHOD source.
    rs-name  = iv_name.
    rs-alias = iv_name.
  ENDMETHOD.


  METHOD exact_name_allowed.
    cl_abap_unit_assert=>assert_true(
      act = zcl_sqlr_allow=>matches( iv_name = `MARA` it_entries = entries( ) )
      msg = 'a name on the list' ).
  ENDMETHOD.

  METHOD exact_name_is_not_prefix.
    " MARA_BACKUP is a different table with different rows, and an entry for
    " MARA says nothing about it.
    cl_abap_unit_assert=>assert_false(
      act = zcl_sqlr_allow=>matches( iv_name = `MARA_BACKUP` it_entries = entries( ) )
      msg = 'an exact entry is not a prefix' ).
  ENDMETHOD.

  METHOD pattern_allowed.
    cl_abap_unit_assert=>assert_true(
      act = zcl_sqlr_allow=>matches( iv_name = `ZSALES_ORDER_LOG` it_entries = entries( ) )
      msg = 'a pattern covers its family' ).
  ENDMETHOD.

  METHOD pattern_does_not_overrun.
    cl_abap_unit_assert=>assert_false(
      act = zcl_sqlr_allow=>matches( iv_name = `ZBETRX_OTHER` it_entries = entries( ) )
      msg = 'a pattern covers only what it names' ).
  ENDMETHOD.

  METHOD lower_case_is_the_same.
    " The guard upper-cases what it collects, but a list maintained by hand
    " will not be consistent, and a table is not two tables because of case.
    cl_abap_unit_assert=>assert_true(
      act = zcl_sqlr_allow=>matches( iv_name = `mara` it_entries = entries( ) )
      msg = 'case does not decide access' ).
  ENDMETHOD.

  METHOD inactive_entry_is_no.
    " Deactivating is how an entry is withdrawn without losing the record of
    " it having been there. It has to take effect immediately.
    cl_abap_unit_assert=>assert_false(
      act = zcl_sqlr_allow=>matches( iv_name = `MARC` it_entries = entries( ) )
      msg = 'an inactive entry allows nothing' ).
  ENDMETHOD.

  METHOD unknown_table_refused.
    cl_abap_unit_assert=>assert_false(
      act = zcl_sqlr_allow=>matches( iv_name = `PA0008` it_entries = entries( ) )
      msg = 'a table nobody listed' ).
  ENDMETHOD.

  METHOD every_source_is_checked.
    " The first source being fine says nothing about the second, which is how
    " a join smuggles a table past a check that stopped at the first one.
    DATA(lt) = VALUE zcl_sqlr_guard=>tt_source(
      ( source( `MARA` ) )
      ( source( `PA0008` ) ) ).
    DATA(ls) = zcl_sqlr_allow=>check( it_sources = lt it_entries = entries( ) ).
    cl_abap_unit_assert=>assert_false( act = ls-ok msg = 'the second source was checked' ).
    cl_abap_unit_assert=>assert_equals( exp = `PA0008` act = ls-refused msg = 'and named' ).
  ENDMETHOD.

  METHOD refusal_names_the_table.
    DATA(lt) = VALUE zcl_sqlr_guard=>tt_source( ( source( `PA0008` ) ) ).
    DATA(ls) = zcl_sqlr_allow=>check( it_sources = lt it_entries = entries( ) ).
    cl_abap_unit_assert=>assert_equals( exp = `NOT_ALLOWED` act = ls-diag-code msg = 'the code' ).
    cl_abap_unit_assert=>assert_char_cp( act = ls-diag-why exp = '*PA0008*' msg = 'the why names it' ).
    cl_abap_unit_assert=>assert_char_cp( act = ls-diag-fix exp = '*activity 02*' msg = 'and what to ask for' ).
  ENDMETHOD.

  METHOD empty_list_allows_nothing.
    " An empty list is not an open door. It is a tool that reads nothing until
    " somebody decides what it may read.
    DATA(lt) = VALUE zcl_sqlr_guard=>tt_source( ( source( `MARA` ) ) ).
    DATA(ls) = zcl_sqlr_allow=>check(
      it_sources = lt
      it_entries = VALUE zcl_sqlr_allow=>tt_entry( ) ).
    cl_abap_unit_assert=>assert_false( act = ls-ok msg = 'nothing is allowed by default' ).
  ENDMETHOD.


  METHOD own_entry_allowed.
    cl_abap_unit_assert=>assert_true(
      act = zcl_sqlr_allow=>matches( iv_name = `MARD` it_entries = entries( ) iv_user = 'ANALYST' )
      msg = 'a grant allows the user it names' ).
  ENDMETHOD.

  METHOD other_users_entry_is_no.
    " The reason per-user lists exist: somebody else's verified table is not
    " yours because it is on a list.
    cl_abap_unit_assert=>assert_false(
      act = zcl_sqlr_allow=>matches( iv_name = `MARD` it_entries = entries( ) iv_user = 'SOMEBODY' )
      " No apostrophe in the message: 'another user''s grant' passed the
      " syntax check and then stopped the class pool generating in a test
      " run, which the runner reports only as "no unit test classes found".
      msg = 'a grant for somebody else allows nothing' ).
  ENDMETHOD.

  METHOD refusal_names_the_user.
    DATA(lt) = VALUE zcl_sqlr_guard=>tt_source( ( source( `MARD` ) ) ).
    DATA(ls) = zcl_sqlr_allow=>check( it_sources = lt it_entries = entries( ) iv_user = 'SOMEBODY' ).
    cl_abap_unit_assert=>assert_char_cp( act = ls-diag-why exp = '*SOMEBODY*'
                                         msg = 'the why says whose list it is not on' ).
  ENDMETHOD.

  METHOD star_is_a_valid_user.
    cl_abap_unit_assert=>assert_true( act = zcl_sqlr_allow=>valid_user( `*` )-ok
                                      msg = '* is everybody, and allowed' ).
  ENDMETHOD.

  METHOD empty_user_refused.
    cl_abap_unit_assert=>assert_equals( exp = `NO_USER`
                                        act = zcl_sqlr_allow=>valid_user( `  ` )-diag-code ).
  ENDMETHOD.


  METHOD plain_table_name_is_valid.
    cl_abap_unit_assert=>assert_true( act = zcl_sqlr_allow=>valid_entry( `EKKO` )-ok ).
  ENDMETHOD.

  METHOD pattern_is_valid.
    cl_abap_unit_assert=>assert_true( act = zcl_sqlr_allow=>valid_entry( `ZSALES_*` )-ok ).
  ENDMETHOD.

  METHOD namespaced_name_is_valid.
    cl_abap_unit_assert=>assert_true( act = zcl_sqlr_allow=>valid_entry( `/BIC/AZDEMO01` )-ok ).
  ENDMETHOD.

  METHOD empty_entry_refused.
    cl_abap_unit_assert=>assert_equals(
      exp = `NO_ENTRY`
      act = zcl_sqlr_allow=>valid_entry( `   ` )-diag-code ).
  ENDMETHOD.

  METHOD a_single_star_refused.
    " Somebody will try it on the first afternoon. It would hand over the
    " tables holding passwords and payroll along with everything else.
    DATA(ls) = zcl_sqlr_allow=>valid_entry( `*` ).
    cl_abap_unit_assert=>assert_false( act = ls-ok msg = 'a star on its own is the whole database' ).
    cl_abap_unit_assert=>assert_equals( exp = `ENTRY_TOO_WIDE` act = ls-diag-code ).
  ENDMETHOD.

  METHOD punctuation_refused.
    cl_abap_unit_assert=>assert_equals(
      exp = `ENTRY_NOT_ALLOWED`
      act = zcl_sqlr_allow=>valid_entry( `MARA; DROP` )-diag-code ).
  ENDMETHOD.

  METHOD a_space_inside_refused.
    cl_abap_unit_assert=>assert_false(
      act = zcl_sqlr_allow=>valid_entry( `TWO NAMES` )-ok
      msg = 'a table name has no space in it' ).
  ENDMETHOD.

ENDCLASS.
