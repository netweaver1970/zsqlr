*"* use this source file for your ABAP unit test classes

" The rewrite, tested through the guard that feeds it.
"
" The sources are not hand-built: every test runs its statement through
" ZCL_SQLR_GUARD first, exactly as the tool does. A rewrite that only works on
" sources somebody typed into a fixture would be a rewrite that works nowhere.
CLASS ltcl_client DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.

    CONSTANTS c_client TYPE symandt VALUE '250'.

    METHODS dep
      IMPORTING iv_names  TYPE string
      RETURNING VALUE(rt) TYPE zcl_sqlr_client=>tt_clientdep.

    METHODS rewritten
      IMPORTING iv_sql        TYPE string
                iv_dependent  TYPE string
      RETURNING VALUE(rv_sql) TYPE string.

    METHODS one_table              FOR TESTING.
    METHODS aliased_table          FOR TESTING.
    METHODS alias_with_as          FOR TESTING.
    METHODS cross_client_untouched FOR TESTING.
    METHODS mixed_statement        FOR TESTING.
    METHODS two_tables_both_done   FOR TESTING.
    METHODS subquery_source        FOR TESTING.
    METHODS union_both_branches    FOR TESTING.
    METHODS quoted_name_kept       FOR TESTING.
    METHODS mandant_column         FOR TESTING.
    METHODS where_clause_intact    FOR TESTING.
    METHODS or_cannot_undo_it      FOR TESTING.
    METHODS rewrite_still_passes   FOR TESTING.

ENDCLASS.


CLASS ltcl_client IMPLEMENTATION.

  METHOD dep.
    SPLIT iv_names AT ',' INTO TABLE DATA(lt_names).
    LOOP AT lt_names INTO DATA(lv_name).
      CONDENSE lv_name.
      IF lv_name IS INITIAL.
        CONTINUE.
      ENDIF.
      DATA(lv_field) = COND string( WHEN lv_name = `T000X` THEN `MANDANT` ELSE `MANDT` ).
      APPEND VALUE #( name = to_upper( lv_name ) field = lv_field ) TO rt.
    ENDLOOP.
  ENDMETHOD.

  METHOD rewritten.
    DATA(ls_guard) = zcl_sqlr_guard=>check( iv_sql ).
    cl_abap_unit_assert=>assert_true( act = ls_guard-ok
                                      msg = |the guard refused the fixture: { ls_guard-diag-why }| ).
    rv_sql = zcl_sqlr_client=>rewrite( iv_sql       = iv_sql
                                       it_sources   = ls_guard-sources
                                       it_clientdep = dep( iv_dependent )
                                       iv_client    = c_client ).
  ENDMETHOD.


  METHOD one_table.
    " No alias in the statement, so the derived table is given the table's own
    " name -- otherwise nothing else in the statement resolves.
    cl_abap_unit_assert=>assert_equals(
      exp = `SELECT * FROM (SELECT * FROM mara WHERE MANDT = '250') MARA`
      act = rewritten( iv_sql = `SELECT * FROM mara` iv_dependent = `MARA` )
      msg = 'one unaliased table' ).
  ENDMETHOD.

  METHOD aliased_table.
    " The author's alias is left where it is; adding a second would not parse.
    cl_abap_unit_assert=>assert_equals(
      exp = `SELECT * FROM (SELECT * FROM mara WHERE MANDT = '250') a WHERE a.matnr = '253'`
      act = rewritten( iv_sql = `SELECT * FROM mara a WHERE a.matnr = '253'` iv_dependent = `MARA` )
      msg = 'an aliased table' ).
  ENDMETHOD.

  METHOD alias_with_as.
    cl_abap_unit_assert=>assert_equals(
      exp = `SELECT * FROM (SELECT * FROM mara WHERE MANDT = '250') AS a`
      act = rewritten( iv_sql = `SELECT * FROM mara AS a` iv_dependent = `MARA` )
      msg = 'an alias written with AS' ).
  ENDMETHOD.

  METHOD cross_client_untouched.
    " A table with no client column is the same in every client. Wrapping it
    " would invent a column and fail at the database.
    cl_abap_unit_assert=>assert_equals(
      exp = `SELECT * FROM t000`
      act = rewritten( iv_sql = `SELECT * FROM t000` iv_dependent = `MARA` )
      msg = 'a cross-client table is left alone' ).
  ENDMETHOD.

  METHOD mixed_statement.
    cl_abap_unit_assert=>assert_equals(
      exp = `SELECT * FROM (SELECT * FROM mara WHERE MANDT = '250') a JOIN t000 b ON a.mandt = b.mandt`
      act = rewritten( iv_sql       = `SELECT * FROM mara a JOIN t000 b ON a.mandt = b.mandt`
                       iv_dependent = `MARA` )
      msg = 'one of each in the same statement' ).
  ENDMETHOD.

  METHOD two_tables_both_done.
    " Splicing front to back would invalidate the second offset. This is the
    " test that catches it.
    DATA(lv) = rewritten( iv_sql       = `SELECT * FROM mara a JOIN marc b ON a.matnr = b.matnr`
                          iv_dependent = `MARA,MARC` ).
    cl_abap_unit_assert=>assert_equals(
      exp = `SELECT * FROM (SELECT * FROM mara WHERE MANDT = '250') a ` &&
            `JOIN (SELECT * FROM marc WHERE MANDT = '250') b ON a.matnr = b.matnr`
      act = lv
      msg = 'both tables, and the text in between unharmed' ).
  ENDMETHOD.

  METHOD subquery_source.
    " The restriction has to reach inside, or a subquery reads every client.
    DATA(lv) = rewritten(
      iv_sql       = `SELECT * FROM mara WHERE matnr IN ( SELECT matnr FROM marc )`
      iv_dependent = `MARA,MARC` ).
    cl_abap_unit_assert=>assert_char_cp(
      act = lv exp = `*IN ( SELECT matnr FROM (SELECT * FROM marc WHERE MANDT = '250') MARC )*`
      msg = 'the subquery source is restricted too' ).
  ENDMETHOD.

  METHOD union_both_branches.
    DATA(lv) = rewritten( iv_sql       = `SELECT matnr FROM mara UNION ALL SELECT matnr FROM marc`
                          iv_dependent = `MARA,MARC` ).
    FIND ALL OCCURRENCES OF `WHERE MANDT = '250'` IN lv MATCH COUNT DATA(lv_count).
    cl_abap_unit_assert=>assert_equals( exp = 2 act = lv_count
                                        msg = 'both branches restricted' ).
  ENDMETHOD.

  METHOD quoted_name_kept.
    " Re-spelling a quoted identifier is how it stops resolving, so the name
    " goes back exactly as it was written.
    cl_abap_unit_assert=>assert_equals(
      exp = `SELECT * FROM (SELECT * FROM "MARA" WHERE MANDT = '250') MARA`
      act = rewritten( iv_sql = `SELECT * FROM "MARA"` iv_dependent = `MARA` )
      msg = 'a quoted name survives the rewrite' ).
  ENDMETHOD.

  METHOD mandant_column.
    " Not every client column is called MANDT.
    cl_abap_unit_assert=>assert_equals(
      exp = `SELECT * FROM (SELECT * FROM t000x WHERE MANDANT = '250') T000X`
      act = rewritten( iv_sql = `SELECT * FROM t000x` iv_dependent = `T000X` )
      msg = 'the column the dictionary named' ).
  ENDMETHOD.

  METHOD where_clause_intact.
    " Nothing outside the FROM clause is touched. The author's conditions are
    " their own; this adds one, it does not edit theirs.
    DATA(lv) = rewritten(
      iv_sql       = `SELECT matnr FROM mara WHERE mtart = 'ZOIL' AND matnr LIKE '2%' ORDER BY matnr`
      iv_dependent = `MARA` ).
    cl_abap_unit_assert=>assert_char_cp(
      act = lv exp = `*WHERE mtart = 'ZOIL' AND matnr LIKE '2%' ORDER BY matnr`
      msg = 'the original tail is unchanged' ).
  ENDMETHOD.

  METHOD or_cannot_undo_it.
    " The reason for the whole approach. Added to the WHERE clause, this OR
    " would make the restriction a no-op; carried by the table, it cannot be.
    DATA(lv) = rewritten(
      iv_sql       = `SELECT * FROM mara WHERE matnr = '253' OR 1 = 1`
      iv_dependent = `MARA` ).
    cl_abap_unit_assert=>assert_char_cp(
      act = lv exp = `SELECT * FROM (SELECT * FROM mara WHERE MANDT = '250') MARA WHERE*`
      msg = 'the restriction sits where an OR cannot reach it' ).
  ENDMETHOD.

  METHOD rewrite_still_passes.
    " What comes out must be something the guard would allow in: the rewrite
    " adds a subquery, and if that ever produced something the guard refuses,
    " the tool would build statements it then rejects.
    DATA(lv) = rewritten( iv_sql       = `SELECT * FROM mara a JOIN marc b ON a.matnr = b.matnr`
                          iv_dependent = `MARA,MARC` ).
    DATA(ls) = zcl_sqlr_guard=>check( lv ).
    cl_abap_unit_assert=>assert_true( act = ls-ok
                                      msg = |the rewrite produced something the guard refuses: { ls-diag-why }| ).
    " And it still reads only the two tables it read before.
    cl_abap_unit_assert=>assert_equals( exp = 2 act = lines( ls-sources )
                                        msg = 'no new table was introduced' ).
  ENDMETHOD.

ENDCLASS.
