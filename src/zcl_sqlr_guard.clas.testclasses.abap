*"* use this source file for your ABAP unit test classes

" The guard's tests are its specification.
"
" Two halves, and the second matters more than the first. The allowed cases
" keep the tool usable: a guard that refuses real reporting SQL gets switched
" off. The refusals are the security, and the evasions among them are the only
" part of this codebase where somebody is actively trying to get past.
CLASS ltcl_guard DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.

    METHODS assert_ok
      IMPORTING iv_sql  TYPE string
                iv_msg  TYPE string.

    METHODS assert_refused
      IMPORTING iv_sql  TYPE string
                iv_code TYPE string
                iv_msg  TYPE string.

    " What may run
    METHODS plain_select            FOR TESTING.
    METHODS join_and_alias          FOR TESTING.
    METHODS comma_join              FOR TESTING.
    METHODS subquery                FOR TESTING.
    METHODS derived_table           FOR TESTING.
    METHODS with_clause             FOR TESTING.
    METHODS union_of_two            FOR TESTING.
    METHODS window_and_case         FOR TESTING.
    METHODS comments_and_newlines   FOR TESTING.
    METHODS quoted_name             FOR TESTING.
    METHODS namespaced_table        FOR TESTING.

    " What may not
    METHODS a_write                 FOR TESTING.
    METHODS a_second_statement      FOR TESTING.
    METHODS select_into             FOR TESTING.
    METHODS procedure_call          FOR TESTING.
    METHODS schema_qualified        FOR TESTING.
    METHODS table_function          FOR TESTING.
    METHODS reads_nothing           FOR TESTING.
    METHODS unbalanced_brackets     FOR TESTING.
    METHODS unterminated_literal    FOR TESTING.
    METHODS unterminated_comment    FOR TESTING.
    METHODS empty_statement         FOR TESTING.

    " Evasions
    METHODS keyword_hidden_in_comment  FOR TESTING.
    METHODS keyword_inside_a_literal   FOR TESTING.
    METHODS semicolon_inside_literal   FOR TESTING.
    METHODS comment_inside_keyword     FOR TESTING.
    METHODS nested_comment             FOR TESTING.
    METHODS write_after_union          FOR TESTING.
    METHODS deep_subquery_source       FOR TESTING.
    METHODS cte_shadowing_a_table      FOR TESTING.
    METHODS mixed_case_drop            FOR TESTING.
    METHODS source_after_join_and_on   FOR TESTING.

    " What reaches the database: comments gone, literals kept.
    METHODS strip_line_comment         FOR TESTING.
    METHODS strip_keeps_dashes_in_text FOR TESTING.
    METHODS strip_nested_block         FOR TESTING.
    METHODS strip_keeps_quoted_name    FOR TESTING.

ENDCLASS.


CLASS ltcl_guard IMPLEMENTATION.

  METHOD assert_ok.
    DATA(ls) = zcl_sqlr_guard=>check( iv_sql ).
    cl_abap_unit_assert=>assert_true(
      act = ls-ok
      msg = |{ iv_msg }: refused with { ls-diag-code } -- { ls-diag-why }| ).
  ENDMETHOD.

  METHOD assert_refused.
    DATA(ls) = zcl_sqlr_guard=>check( iv_sql ).
    cl_abap_unit_assert=>assert_false(
      act = ls-ok
      msg = |{ iv_msg }: this was allowed through| ).
    cl_abap_unit_assert=>assert_equals(
      exp = iv_code
      act = ls-diag-code
      msg = |{ iv_msg }: refused, but for the wrong reason| ).
    " Every refusal has to be actionable, or the user is left guessing.
    cl_abap_unit_assert=>assert_not_initial( act = ls-diag-what msg = 'no "what"' ).
    cl_abap_unit_assert=>assert_not_initial( act = ls-diag-why  msg = 'no "why"' ).
    cl_abap_unit_assert=>assert_not_initial( act = ls-diag-fix  msg = 'no "fix"' ).
  ENDMETHOD.


  " ---------------------------------------------------------------- allowed

  METHOD plain_select.
    DATA(ls) = zcl_sqlr_guard=>check( `SELECT matnr, werks FROM marc WHERE werks = 'ZD14'` ).
    cl_abap_unit_assert=>assert_true( act = ls-ok msg = 'a plain select' ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( ls-sources ) msg = 'one source' ).
    cl_abap_unit_assert=>assert_equals( exp = `MARC` act = ls-sources[ 1 ]-name msg = 'the table' ).
  ENDMETHOD.

  METHOD join_and_alias.
    DATA(ls) = zcl_sqlr_guard=>check(
      `SELECT a.matnr FROM mara AS a INNER JOIN marc m ON a.matnr = m.matnr WHERE m.werks = 'ZD14'` ).
    cl_abap_unit_assert=>assert_true( act = ls-ok msg = 'a join' ).
    cl_abap_unit_assert=>assert_equals( exp = 2 act = lines( ls-sources ) msg = 'both tables found' ).
    cl_abap_unit_assert=>assert_equals( exp = `MARA` act = ls-sources[ 1 ]-name  msg = 'first' ).
    cl_abap_unit_assert=>assert_equals( exp = `A`    act = ls-sources[ 1 ]-alias msg = 'its alias' ).
    cl_abap_unit_assert=>assert_equals( exp = `MARC` act = ls-sources[ 2 ]-name  msg = 'second' ).
    cl_abap_unit_assert=>assert_equals( exp = `M`    act = ls-sources[ 2 ]-alias msg = 'its alias' ).
  ENDMETHOD.

  METHOD comma_join.
    DATA(ls) = zcl_sqlr_guard=>check( `SELECT * FROM mara a, marc b, mard c WHERE a.matnr = b.matnr` ).
    cl_abap_unit_assert=>assert_true( act = ls-ok msg = 'old-style join' ).
    cl_abap_unit_assert=>assert_equals( exp = 3 act = lines( ls-sources ) msg = 'all three found' ).
  ENDMETHOD.

  METHOD subquery.
    DATA(ls) = zcl_sqlr_guard=>check(
      `SELECT * FROM mara WHERE matnr IN ( SELECT matnr FROM marc WHERE werks = 'ZD14' )` ).
    cl_abap_unit_assert=>assert_true( act = ls-ok msg = 'a subquery' ).
    cl_abap_unit_assert=>assert_equals( exp = 2 act = lines( ls-sources ) msg = 'both found' ).
  ENDMETHOD.

  METHOD derived_table.
    " The bracket is not a table; what is inside it is.
    DATA(ls) = zcl_sqlr_guard=>check( `SELECT * FROM ( SELECT matnr FROM mara ) AS x` ).
    cl_abap_unit_assert=>assert_true( act = ls-ok msg = 'a derived table' ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( ls-sources ) msg = 'one real source' ).
    cl_abap_unit_assert=>assert_equals( exp = `MARA` act = ls-sources[ 1 ]-name msg = 'the inner table' ).
  ENDMETHOD.

  METHOD with_clause.
    DATA(ls) = zcl_sqlr_guard=>check(
      `WITH recent AS ( SELECT matnr FROM marc WHERE werks = 'ZD14' ) ` &&
      `SELECT * FROM recent JOIN mara ON mara.matnr = recent.matnr` ).
    cl_abap_unit_assert=>assert_true( act = ls-ok msg = 'a with clause' ).
    " RECENT is the statement's own name, not a table, so it is not a source.
    cl_abap_unit_assert=>assert_equals( exp = 2 act = lines( ls-sources ) msg = 'marc and mara only' ).
    READ TABLE ls-sources TRANSPORTING NO FIELDS WITH KEY name = `RECENT`.
    cl_abap_unit_assert=>assert_subrc( exp = 4 msg = 'the CTE name is not a table' ).
  ENDMETHOD.

  METHOD union_of_two.
    assert_ok( iv_sql = `SELECT matnr FROM mara UNION ALL SELECT matnr FROM marc`
               iv_msg = 'union' ).
  ENDMETHOD.

  METHOD window_and_case.
    assert_ok(
      iv_sql = `SELECT matnr, CASE WHEN werks = 'ZD14' THEN 1 ELSE 0 END AS flag, ` &&
               `ROW_NUMBER() OVER ( PARTITION BY matnr ORDER BY werks ) AS rn FROM marc`
      iv_msg = 'window function and CASE ... END' ).
  ENDMETHOD.

  METHOD comments_and_newlines.
    assert_ok(
      iv_sql = |SELECT matnr -- the material\n| &&
               |FROM marc /* the plant view */\n| &&
               |WHERE werks = 'ZD14'|
      iv_msg = 'comments of both kinds' ).
  ENDMETHOD.

  METHOD quoted_name.
    DATA(ls) = zcl_sqlr_guard=>check( `SELECT * FROM "MARC" WHERE werks = 'ZD14'` ).
    cl_abap_unit_assert=>assert_true( act = ls-ok msg = 'a quoted table name' ).
    cl_abap_unit_assert=>assert_equals( exp = `MARC` act = ls-sources[ 1 ]-name msg = 'unquoted' ).
  ENDMETHOD.

  METHOD namespaced_table.
    DATA(ls) = zcl_sqlr_guard=>check( `SELECT * FROM /bic/azdemo01` ).
    cl_abap_unit_assert=>assert_true( act = ls-ok msg = 'a namespaced table' ).
    cl_abap_unit_assert=>assert_equals( exp = `/BIC/AZDEMO01` act = ls-sources[ 1 ]-name msg = 'whole name' ).
  ENDMETHOD.


  " ---------------------------------------------------------------- refused

  METHOD a_write.
    assert_refused( iv_sql  = `DELETE FROM mara WHERE matnr = '253'`
                    iv_code = `NOT_A_SELECT`
                    iv_msg  = 'a delete' ).
  ENDMETHOD.

  METHOD a_second_statement.
    assert_refused( iv_sql  = `SELECT * FROM mara; DROP TABLE mara`
                    iv_code = `SECOND_STATEMENT`
                    iv_msg  = 'two statements' ).
  ENDMETHOD.

  METHOD select_into.
    assert_refused( iv_sql  = `SELECT * INTO newtab FROM mara`
                    iv_code = `FORBIDDEN`
                    iv_msg  = 'select into' ).
  ENDMETHOD.

  METHOD procedure_call.
    assert_refused( iv_sql  = `CALL my_procedure( 1 )`
                    iv_code = `NOT_A_SELECT`
                    iv_msg  = 'a procedure call' ).
  ENDMETHOD.

  METHOD schema_qualified.
    assert_refused( iv_sql  = `SELECT * FROM saphanadb.mara`
                    iv_code = `SCHEMA_QUALIFIED`
                    iv_msg  = 'a schema-qualified name' ).
  ENDMETHOD.

  METHOD table_function.
    assert_refused( iv_sql  = `SELECT * FROM series_generate_integer( 1, 1, 100 )`
                    iv_code = `TABLE_FUNCTION`
                    iv_msg  = 'a table function' ).
  ENDMETHOD.

  METHOD reads_nothing.
    " Nothing to approve means nothing to run. A SELECT with no FROM is also
    " how somebody probes the database for what it will evaluate.
    assert_refused( iv_sql  = `SELECT 1 + 1`
                    iv_code = `NO_SOURCE`
                    iv_msg  = 'a select without a from' ).
  ENDMETHOD.

  METHOD unbalanced_brackets.
    assert_refused( iv_sql  = `SELECT * FROM mara WHERE matnr IN ( SELECT matnr FROM marc`
                    iv_code = `UNBALANCED`
                    iv_msg  = 'a missing bracket' ).
  ENDMETHOD.

  METHOD unterminated_literal.
    assert_refused( iv_sql  = `SELECT * FROM mara WHERE matnr = 'abc`
                    iv_code = `UNTERMINATED_LITERAL`
                    iv_msg  = 'an open quote' ).
  ENDMETHOD.

  METHOD unterminated_comment.
    assert_refused( iv_sql  = `SELECT * FROM mara /* never closed`
                    iv_code = `UNTERMINATED_COMMENT`
                    iv_msg  = 'an open comment' ).
  ENDMETHOD.

  METHOD empty_statement.
    assert_refused( iv_sql  = `   `
                    iv_code = `EMPTY`
                    iv_msg  = 'whitespace only' ).
  ENDMETHOD.


  " --------------------------------------------------------------- evasions

  METHOD keyword_hidden_in_comment.
    " The DROP is inside a comment and must not be read as syntax -- but it
    " must not make the statement fail either. It is a comment.
    assert_ok( iv_sql = `SELECT * FROM mara /* DROP TABLE mara */ WHERE matnr = '253'`
               iv_msg = 'a keyword inside a comment' ).
  ENDMETHOD.

  METHOD keyword_inside_a_literal.
    " A material number that happens to read DELETE is data, not syntax.
    assert_ok( iv_sql = `SELECT * FROM mara WHERE matnr = 'DELETE FROM mara'`
               iv_msg = 'a keyword inside a literal' ).
  ENDMETHOD.

  METHOD semicolon_inside_literal.
    assert_ok( iv_sql = `SELECT * FROM mara WHERE matnr = 'a;b'`
               iv_msg = 'a semicolon inside a literal' ).
  ENDMETHOD.

  METHOD comment_inside_keyword.
    " SEL/**/ECT is not SELECT to any parser worth the name, and it is not one
    " here either: the comment separates two words, neither of which is SELECT.
    assert_refused( iv_sql  = `SEL/**/ECT * FROM mara`
                    iv_code = `NOT_A_SELECT`
                    iv_msg  = 'a comment splitting a keyword' ).
  ENDMETHOD.

  METHOD nested_comment.
    " The inner */ closes only the inner comment. If nesting were not counted,
    " the trailing text would be outside the comment and would be syntax.
    assert_ok( iv_sql = `SELECT * FROM mara /* outer /* inner */ still a comment */ WHERE matnr = '253'`
               iv_msg = 'a nested comment' ).
  ENDMETHOD.

  METHOD write_after_union.
    assert_refused( iv_sql  = `SELECT matnr FROM mara UNION ALL DELETE FROM marc`
                    iv_code = `FORBIDDEN`
                    iv_msg  = 'a write hidden behind a union' ).
  ENDMETHOD.

  METHOD deep_subquery_source.
    " Three levels down is still a source, and the allow-list must see it.
    DATA(ls) = zcl_sqlr_guard=>check(
      `SELECT * FROM mara WHERE matnr IN ( ` &&
      `  SELECT matnr FROM marc WHERE werks IN ( ` &&
      `    SELECT werks FROM t001w WHERE land1 IN ( SELECT land1 FROM t005 ) ) )` ).
    cl_abap_unit_assert=>assert_true( act = ls-ok msg = 'nested subqueries' ).
    cl_abap_unit_assert=>assert_equals( exp = 4 act = lines( ls-sources )
                                        msg = 'every level is a source the list must approve' ).
    READ TABLE ls-sources TRANSPORTING NO FIELDS WITH KEY name = `T005`.
    cl_abap_unit_assert=>assert_subrc( exp = 0 msg = 'the deepest one was seen' ).
  ENDMETHOD.

  METHOD cte_shadowing_a_table.
    " A CTE named MARA hides the real MARA. The query reads only what the CTE
    " reads, so MARC is the source the allow-list must approve.
    DATA(ls) = zcl_sqlr_guard=>check(
      `WITH mara AS ( SELECT matnr FROM marc ) SELECT * FROM mara` ).
    cl_abap_unit_assert=>assert_true( act = ls-ok msg = 'a CTE shadowing a table' ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( ls-sources ) msg = 'only the real read' ).
    cl_abap_unit_assert=>assert_equals( exp = `MARC` act = ls-sources[ 1 ]-name msg = 'marc' ).
  ENDMETHOD.

  METHOD mixed_case_drop.
    assert_refused( iv_sql  = `SELECT * FROM mara WHERE 1 = 1 UNION SELECT * FROM mara; dRoP TaBlE mara`
                    iv_code = `SECOND_STATEMENT`
                    iv_msg  = 'mixed case after a semicolon' ).
  ENDMETHOD.

  METHOD source_after_join_and_on.
    " FROM a JOIN b ON ... , c -- the c after the ON clause is a third source
    " and has to be checked like the others. Found by this test, which the
    " first version of the parser failed: the scan stopped at ON.
    DATA(ls) = zcl_sqlr_guard=>check(
      `SELECT * FROM mara a JOIN marc b ON a.matnr = b.matnr, mard c WHERE c.lgort = '0001'` ).
    cl_abap_unit_assert=>assert_true( act = ls-ok msg = 'comma source after an ON clause' ).
    READ TABLE ls-sources TRANSPORTING NO FIELDS WITH KEY name = `MARD`.
    cl_abap_unit_assert=>assert_subrc( exp = 0 msg = 'the source after the ON clause was seen' ).
  ENDMETHOD.

  METHOD strip_line_comment.
    " The case that broke ADBC: an apostrophe in a comment.
    DATA(lv) = zcl_sqlr_guard=>without_comments(
      |SELECT matnr -- the item's material\nFROM mara| ).
    cl_abap_unit_assert=>assert_equals( exp = |SELECT matnr \nFROM mara| act = lv
                                        msg = 'a line comment is dropped, its line break kept' ).
  ENDMETHOD.

  METHOD strip_keeps_dashes_in_text.
    DATA(lv) = zcl_sqlr_guard=>without_comments(
      `SELECT * FROM mara WHERE matnr = 'A--B' AND mtart = 'X''Y' -- gone` ).
    cl_abap_unit_assert=>assert_equals(
      exp = `SELECT * FROM mara WHERE matnr = 'A--B' AND mtart = 'X''Y' `
      act = lv msg = 'dashes and a doubled quote inside a literal are data' ).
  ENDMETHOD.

  METHOD strip_nested_block.
    DATA(lv) = zcl_sqlr_guard=>without_comments(
      `SELECT /* outer /* inner */ still outer */ matnr FROM mara` ).
    cl_abap_unit_assert=>assert_equals( exp = `SELECT   matnr FROM mara` act = lv
                                        msg = 'a nested block comment goes whole, as one space' ).
  ENDMETHOD.

  METHOD strip_keeps_quoted_name.
    DATA(lv) = zcl_sqlr_guard=>without_comments(
      `SELECT "A--B" FROM mara /* x */` ).
    cl_abap_unit_assert=>assert_equals( exp = `SELECT "A--B" FROM mara  ` act = lv
                                        msg = 'a quoted name is kept as typed' ).
  ENDMETHOD.

ENDCLASS.
