" The guard: what may reach the database, and nothing else.
"
" This is the security boundary of the whole tool (spec 037 §3). The statement
" runs as native SQL on the application's own connection, so the database will
" execute whatever gets past here with the application's full rights. Which is
" why this class recognises the grammar it permits and refuses everything else,
" rather than scanning for words it dislikes: a blacklist loses to the first
" construct nobody thought of, and HANA SQL is a large language.
"
" No database, no UI, no authorisations. Everything here is a function of the
" statement text, which is what lets the whole of it be tested in ABAP Unit.
CLASS zcl_sqlr_guard DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.

    " A table or view the statement reads. Offset and length are kept so the
    " client rewriter can splice at exactly the right place and a refusal can
    " point at the text rather than describe it.
    TYPES: BEGIN OF ty_source,
             name    TYPE string,
             alias   TYPE string,
             " Whether the author wrote an alias. The client rewriter needs to
             " know: it replaces the name with a derived table, and a derived
             " table must carry a name -- so it supplies one when the statement
             " did not, and leaves the author's alone when it did.
             aliased TYPE abap_bool,
             offset  TYPE i,
             length  TYPE i,
           END OF ty_source.
    TYPES tt_source TYPE STANDARD TABLE OF ty_source WITH EMPTY KEY.

    " The three-part answer: what we were doing, why it stopped, what to do.
    TYPES: BEGIN OF ty_diag,
             code TYPE string,
             what TYPE string,
             why  TYPE string,
             fix  TYPE string,
           END OF ty_diag.

    TYPES: BEGIN OF ty_result,
             ok      TYPE abap_bool,
             sources TYPE tt_source,
             ctes    TYPE string_table,
             diag    TYPE ty_diag,
           END OF ty_result.

    "! Reads a statement and says whether it may run, and what it reads.
    "! Never raises: a refusal is a result with ok = abap_false and a diagnosis.
    CLASS-METHODS check
      IMPORTING iv_sql           TYPE string
      RETURNING VALUE(rs_result) TYPE ty_result.

  PRIVATE SECTION.

    CONSTANTS c_word_start TYPE string
      VALUE 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_#$'.
    CONSTANTS c_word_rest TYPE string
      VALUE 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_#$0123456789'.
    CONSTANTS c_digits TYPE string VALUE '0123456789'.

    " Kinds of token. A literal keeps no content: once a string is recognised
    " it can never be read as syntax again, which is what makes a semicolon or
    " a keyword inside quotes harmless.
    CONSTANTS: BEGIN OF c_kind,
                 word   TYPE c LENGTH 1 VALUE 'W',
                 quoted TYPE c LENGTH 1 VALUE 'Q',
                 lit    TYPE c LENGTH 1 VALUE 'L',
                 num    TYPE c LENGTH 1 VALUE 'N',
                 punct  TYPE c LENGTH 1 VALUE 'P',
               END OF c_kind.

    TYPES: BEGIN OF ty_token,
             kind   TYPE c LENGTH 1,
             value  TYPE string,
             upper  TYPE string,
             offset TYPE i,
             length TYPE i,
             depth  TYPE i,
           END OF ty_token.
    TYPES tt_token TYPE STANDARD TABLE OF ty_token WITH EMPTY KEY.

    " Everything that is not a read. Over-refusing is the safe direction: a
    " column genuinely called SET can be written "SET" and comes through as a
    " quoted identifier.
    CLASS-METHODS forbidden_words RETURNING VALUE(rt_words) TYPE string_table.

    " Where a FROM clause stops. Anything in this list, at the FROM's own
    " bracket depth, ends the list of sources.
    "
    " ON and USING are deliberately NOT here. They open a join condition, and
    " the clause carries on afterwards: in
    "   FROM a JOIN b ON a.x = b.x, c
    " the c is a third source, and a scan that stopped at ON would never see
    " it -- so the allow-list would never be asked about it. That is the one
    " way a table gets read without being approved, and a test exists for it.
    CLASS-METHODS clause_enders RETURNING VALUE(rt_words) TYPE string_table.

    " Words that may follow a source without being its alias. The enders, plus
    " the join words: "JOIN marc ON ..." must not read ON as the alias of marc.
    CLASS-METHODS alias_stoppers RETURNING VALUE(rt_words) TYPE string_table.

    CLASS-METHODS tokenize
      IMPORTING iv_sql       TYPE string
      EXPORTING et_tokens    TYPE tt_token
                es_diag      TYPE ty_diag
      RETURNING VALUE(rv_ok) TYPE abap_bool.

    CLASS-METHODS collect_ctes
      IMPORTING it_tokens      TYPE tt_token
      RETURNING VALUE(rt_ctes) TYPE string_table.

    CLASS-METHODS collect_sources
      IMPORTING it_tokens    TYPE tt_token
                it_ctes      TYPE string_table
      EXPORTING et_sources   TYPE tt_source
                es_diag      TYPE ty_diag
      RETURNING VALUE(rv_ok) TYPE abap_bool.

    CLASS-METHODS refuse
      IMPORTING iv_code          TYPE string
                iv_what          TYPE string
                iv_why           TYPE string
                iv_fix           TYPE string
      RETURNING VALUE(rs_result) TYPE ty_result.

ENDCLASS.


CLASS zcl_sqlr_guard IMPLEMENTATION.

  METHOD check.

    DATA lt_tokens TYPE tt_token.
    DATA ls_diag   TYPE ty_diag.

    IF iv_sql IS INITIAL.
      rs_result = refuse(
        iv_code = 'EMPTY'
        iv_what = 'Checking the statement.'
        iv_why  = 'There is no statement to check.'
        iv_fix  = 'Type a SELECT and check it again.' ).
      RETURN.
    ENDIF.

    " 1. Tokenise. Comments and literals stop being syntax here.
    IF tokenize( EXPORTING iv_sql    = iv_sql
                 IMPORTING et_tokens = lt_tokens
                           es_diag   = ls_diag ) = abap_false.
      rs_result-diag = ls_diag.
      RETURN.
    ENDIF.

    IF lt_tokens IS INITIAL.
      rs_result = refuse(
        iv_code = 'EMPTY'
        iv_what = 'Checking the statement.'
        iv_why  = 'The statement is only comments and whitespace.'
        iv_fix  = 'Type a SELECT and check it again.' ).
      RETURN.
    ENDIF.

    " 2. One statement. A semicolon inside a literal is not a semicolon, which
    "    is why this runs after tokenising rather than on the raw text.
    LOOP AT lt_tokens INTO DATA(ls_semi) WHERE kind = 'P' AND value = ';'.
      DATA(lv_index) = sy-tabix.
      IF lv_index < lines( lt_tokens ).
        rs_result = refuse(
          iv_code = 'SECOND_STATEMENT'
          iv_what = 'Checking the statement.'
          iv_why  = |A second statement was found after the semicolon at position { ls_semi-offset }.|
          iv_fix  = 'This tool runs one SELECT at a time. Remove everything after the semicolon.' ).
        RETURN.
      ENDIF.
      DELETE lt_tokens INDEX lv_index.
    ENDLOOP.

    " 3. The first keyword. Leading brackets are allowed: a statement may open
    "    with (SELECT ...) UNION (SELECT ...).
    DATA ls_first TYPE ty_token.
    LOOP AT lt_tokens INTO DATA(ls_scan).
      IF ls_scan-kind = 'P' AND ls_scan-value = '('.
        CONTINUE.
      ENDIF.
      ls_first = ls_scan.
      EXIT.
    ENDLOOP.
    IF ls_first-kind <> 'W' OR ( ls_first-upper <> 'SELECT' AND ls_first-upper <> 'WITH' ).
      rs_result = refuse(
        iv_code = 'NOT_A_SELECT'
        iv_what = 'Checking the statement.'
        iv_why  = |A statement has to begin with SELECT or WITH, and this one begins with { ls_first-value }.|
        iv_fix  = 'This tool reads; it does not write. Only SELECT statements run here.' ).
      RETURN.
    ENDIF.

    " 4. Constructs that are not reads. The whitelist above is the mechanism;
    "    this is the belt to its braces.
    DATA(lt_forbidden) = forbidden_words( ).
    LOOP AT lt_tokens INTO DATA(ls_token) WHERE kind = 'W'.
      READ TABLE lt_forbidden TRANSPORTING NO FIELDS WITH KEY table_line = ls_token-upper.
      IF sy-subrc = 0.
        rs_result = refuse(
          iv_code = 'FORBIDDEN'
          iv_what = 'Checking the statement.'
          iv_why  = |{ ls_token-value } at position { ls_token-offset } is not part of a read.|
          iv_fix  = 'Remove it. If it is meant to be a column or table name, write it in double quotes.' ).
        RETURN.
      ENDIF.
    ENDLOOP.

    " 5 and 6. What the statement reads.
    rs_result-ctes = collect_ctes( lt_tokens ).

    IF collect_sources( EXPORTING it_tokens  = lt_tokens
                                  it_ctes    = rs_result-ctes
                        IMPORTING et_sources = rs_result-sources
                                  es_diag    = ls_diag ) = abap_false.
      CLEAR: rs_result-sources, rs_result-ctes.
      rs_result-diag = ls_diag.
      RETURN.
    ENDIF.

    IF rs_result-sources IS INITIAL.
      rs_result = refuse(
        iv_code = 'NO_SOURCE'
        iv_what = 'Checking the statement.'
        iv_why  = 'The statement reads no table at all.'
        iv_fix  = 'A report has to read something. Add a FROM clause.' ).
      RETURN.
    ENDIF.

    rs_result-ok = abap_true.

  ENDMETHOD.


  METHOD tokenize.

    DATA lv_i     TYPE i VALUE 0.
    DATA lv_depth TYPE i VALUE 0.
    DATA lv_start TYPE i.
    DATA lv_name  TYPE string.
    DATA ls_token TYPE ty_token.

    rv_ok = abap_true.
    CLEAR: et_tokens, es_diag.

    DATA(lv_len) = strlen( iv_sql ).
    DATA(lv_lf)  = cl_abap_char_utilities=>newline.
    DATA(lv_cr)  = cl_abap_char_utilities=>cr_lf(1).
    DATA(lv_tab) = cl_abap_char_utilities=>horizontal_tab.

    WHILE lv_i < lv_len.

      DATA(lv_c) = iv_sql+lv_i(1).

      " Whitespace, including the line breaks a pasted statement is full of.
      IF lv_c = ` ` OR lv_c = lv_tab OR lv_c = lv_lf OR lv_c = lv_cr.
        lv_i = lv_i + 1.
        CONTINUE.
      ENDIF.

      " A line comment runs to the end of the line and is dropped whole.
      IF lv_c = '-' AND lv_i + 2 <= lv_len AND iv_sql+lv_i(2) = '--'.
        WHILE lv_i < lv_len AND iv_sql+lv_i(1) <> lv_lf AND iv_sql+lv_i(1) <> lv_cr.
          lv_i = lv_i + 1.
        ENDWHILE.
        CONTINUE.
      ENDIF.

      " A block comment, counted rather than searched for, so that a nested
      " one cannot end the outer comment early and let text out.
      IF lv_c = '/' AND lv_i + 2 <= lv_len AND iv_sql+lv_i(2) = '/*'.
        DATA(lv_nest) = 1.
        lv_start = lv_i.
        lv_i = lv_i + 2.
        WHILE lv_i < lv_len AND lv_nest > 0.
          IF lv_i + 2 <= lv_len AND iv_sql+lv_i(2) = '/*'.
            lv_nest = lv_nest + 1.
            lv_i = lv_i + 2.
          ELSEIF lv_i + 2 <= lv_len AND iv_sql+lv_i(2) = '*/'.
            lv_nest = lv_nest - 1.
            lv_i = lv_i + 2.
          ELSE.
            lv_i = lv_i + 1.
          ENDIF.
        ENDWHILE.
        IF lv_nest > 0.
          es_diag-code = 'UNTERMINATED_COMMENT'.
          es_diag-what = 'Reading the statement.'.
          es_diag-why  = |The comment opened at position { lv_start } is never closed.|.
          es_diag-fix  = 'Close it with */ and check again.'.
          rv_ok = abap_false.
          RETURN.
        ENDIF.
        CONTINUE.
      ENDIF.

      " A string literal. Its contents are thrown away: whatever a person put
      " between the quotes, it is data and can never be syntax.
      IF lv_c = `'`.
        lv_start = lv_i.
        lv_i = lv_i + 1.
        DATA(lv_closed) = abap_false.
        WHILE lv_i < lv_len.
          IF iv_sql+lv_i(1) = `'`.
            IF lv_i + 2 <= lv_len AND iv_sql+lv_i(2) = `''`.
              lv_i = lv_i + 2.
              CONTINUE.
            ENDIF.
            lv_i = lv_i + 1.
            lv_closed = abap_true.
            EXIT.
          ENDIF.
          lv_i = lv_i + 1.
        ENDWHILE.
        IF lv_closed = abap_false.
          es_diag-code = 'UNTERMINATED_LITERAL'.
          es_diag-what = 'Reading the statement.'.
          es_diag-why  = |The text opened with a quote at position { lv_start } is never closed.|.
          es_diag-fix  = 'Close the quote and check again.'.
          rv_ok = abap_false.
          RETURN.
        ENDIF.
        CLEAR ls_token.
        ls_token-kind   = 'L'.
        ls_token-value  = `'...'`.
        ls_token-upper  = `'...'`.
        ls_token-offset = lv_start.
        ls_token-length = lv_i - lv_start.
        ls_token-depth  = lv_depth.
        APPEND ls_token TO et_tokens.
        CONTINUE.
      ENDIF.

      " A quoted identifier keeps its text: it names something.
      IF lv_c = '"'.
        lv_start = lv_i.
        lv_i = lv_i + 1.
        CLEAR lv_name.
        lv_closed = abap_false.
        WHILE lv_i < lv_len.
          IF iv_sql+lv_i(1) = '"'.
            IF lv_i + 2 <= lv_len AND iv_sql+lv_i(2) = '""'.
              lv_name = lv_name && '"'.
              lv_i = lv_i + 2.
              CONTINUE.
            ENDIF.
            lv_i = lv_i + 1.
            lv_closed = abap_true.
            EXIT.
          ENDIF.
          lv_name = lv_name && iv_sql+lv_i(1).
          lv_i = lv_i + 1.
        ENDWHILE.
        IF lv_closed = abap_false.
          es_diag-code = 'UNTERMINATED_NAME'.
          es_diag-what = 'Reading the statement.'.
          es_diag-why  = |The name opened with a double quote at position { lv_start } is never closed.|.
          es_diag-fix  = 'Close the double quote and check again.'.
          rv_ok = abap_false.
          RETURN.
        ENDIF.
        CLEAR ls_token.
        ls_token-kind   = 'Q'.
        ls_token-value  = lv_name.
        ls_token-upper  = to_upper( lv_name ).
        ls_token-offset = lv_start.
        ls_token-length = lv_i - lv_start.
        ls_token-depth  = lv_depth.
        APPEND ls_token TO et_tokens.
        CONTINUE.
      ENDIF.

      " A namespaced name: /BIC/AZ... A slash anywhere else is division.
      IF lv_c = '/' AND lv_i + 1 < lv_len AND substring( val = iv_sql off = lv_i + 1 len = 1 ) CA c_word_start.
        lv_start = lv_i.
        lv_i = lv_i + 1.
        WHILE lv_i < lv_len AND ( iv_sql+lv_i(1) CA c_word_rest OR iv_sql+lv_i(1) = '/' ).
          lv_i = lv_i + 1.
        ENDWHILE.
        CLEAR ls_token.
        ls_token-kind   = 'W'.
        ls_token-value  = substring( val = iv_sql off = lv_start len = lv_i - lv_start ).
        ls_token-upper  = to_upper( ls_token-value ).
        ls_token-offset = lv_start.
        ls_token-length = lv_i - lv_start.
        ls_token-depth  = lv_depth.
        APPEND ls_token TO et_tokens.
        CONTINUE.
      ENDIF.

      " A word: keyword or identifier. Which of the two it is, is decided by
      " where it sits, not here.
      IF lv_c CA c_word_start.
        lv_start = lv_i.
        WHILE lv_i < lv_len AND iv_sql+lv_i(1) CA c_word_rest.
          lv_i = lv_i + 1.
        ENDWHILE.
        CLEAR ls_token.
        ls_token-kind   = 'W'.
        ls_token-value  = substring( val = iv_sql off = lv_start len = lv_i - lv_start ).
        ls_token-upper  = to_upper( ls_token-value ).
        ls_token-offset = lv_start.
        ls_token-length = lv_i - lv_start.
        ls_token-depth  = lv_depth.
        APPEND ls_token TO et_tokens.
        CONTINUE.
      ENDIF.

      IF lv_c CA c_digits.
        lv_start = lv_i.
        WHILE lv_i < lv_len AND ( iv_sql+lv_i(1) CA c_digits OR iv_sql+lv_i(1) = '.' ).
          lv_i = lv_i + 1.
        ENDWHILE.
        CLEAR ls_token.
        ls_token-kind   = 'N'.
        ls_token-value  = substring( val = iv_sql off = lv_start len = lv_i - lv_start ).
        ls_token-upper  = ls_token-value.
        ls_token-offset = lv_start.
        ls_token-length = lv_i - lv_start.
        ls_token-depth  = lv_depth.
        APPEND ls_token TO et_tokens.
        CONTINUE.
      ENDIF.

      " Everything else is one punctuation character. Depth is carried on the
      " token so the FROM clause can be read at its own bracket level.
      CLEAR ls_token.
      ls_token-kind   = 'P'.
      ls_token-value  = lv_c.
      ls_token-upper  = lv_c.
      ls_token-offset = lv_i.
      ls_token-length = 1.
      IF lv_c = '('.
        ls_token-depth = lv_depth.
        lv_depth = lv_depth + 1.
      ELSEIF lv_c = ')'.
        lv_depth = lv_depth - 1.
        ls_token-depth = lv_depth.
      ELSE.
        ls_token-depth = lv_depth.
      ENDIF.
      APPEND ls_token TO et_tokens.
      lv_i = lv_i + 1.

    ENDWHILE.

    IF lv_depth <> 0.
      DATA lv_direction TYPE string.
      IF lv_depth > 0.
        lv_direction = 'too few closing brackets'.
      ELSE.
        lv_direction = 'too many closing brackets'.
      ENDIF.
      es_diag-code = 'UNBALANCED'.
      es_diag-what = 'Reading the statement.'.
      es_diag-why  = |The brackets do not balance: { lv_direction }.|.
      es_diag-fix  = 'Balance the brackets and check again.'.
      rv_ok = abap_false.
      CLEAR et_tokens.
    ENDIF.

  ENDMETHOD.


  METHOD collect_ctes.

    " The names a WITH clause introduces. They look like tables in a FROM and
    " are not: they are the statement's own, and checking them against the
    " allow-list would refuse a legitimate query. What they read is checked,
    " because their own FROM clauses are scanned like any other.
    DATA(lv_total) = lines( it_tokens ).

    LOOP AT it_tokens INTO DATA(ls_name) WHERE kind = 'W'.
      DATA(lv_idx) = sy-tabix.
      IF lv_idx = 1 OR lv_idx + 2 > lv_total.
        CONTINUE.
      ENDIF.
      DATA(ls_prev) = it_tokens[ lv_idx - 1 ].
      DATA(ls_as)   = it_tokens[ lv_idx + 1 ].
      DATA(ls_open) = it_tokens[ lv_idx + 2 ].
      IF ls_as-kind = 'W' AND ls_as-upper = 'AS'
         AND ls_open-kind = 'P' AND ls_open-value = '('
         AND ( ( ls_prev-kind = 'W' AND ( ls_prev-upper = 'WITH' OR ls_prev-upper = 'RECURSIVE' ) )
            OR ( ls_prev-kind = 'P' AND ls_prev-value = ',' ) ).
        APPEND ls_name-upper TO rt_ctes.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD collect_sources.

    DATA ls_source TYPE ty_source.

    rv_ok = abap_true.
    CLEAR: et_sources, es_diag.

    DATA(lt_enders)   = clause_enders( ).
    DATA(lt_stoppers) = alias_stoppers( ).
    DATA(lv_total)    = lines( it_tokens ).

    " Every FROM and every JOIN, at every depth, including the ones inside a
    " WITH clause or three subqueries down.
    LOOP AT it_tokens INTO DATA(ls_from) WHERE kind = 'W' AND ( upper = 'FROM' OR upper = 'JOIN' ).

      DATA(lv_at)     = sy-tabix.
      DATA(lv_depth)  = ls_from-depth.
      DATA(lv_expect) = abap_true.
      DATA(lv_j)      = lv_at + 1.

      WHILE lv_j <= lv_total.

        DATA(ls_n) = it_tokens[ lv_j ].

        " Out of the clause: a closing bracket below our level ends it.
        IF ls_n-depth < lv_depth.
          EXIT.
        ENDIF.

        IF ls_n-depth = lv_depth AND ls_n-kind = 'W'.
          READ TABLE lt_enders TRANSPORTING NO FIELDS WITH KEY table_line = ls_n-upper.
          IF sy-subrc = 0.
            EXIT.
          ENDIF.
        ENDIF.

        IF lv_expect = abap_true.

          IF ls_n-kind = 'P' AND ls_n-value = '('.
            " A derived table. Its own FROM is found by this same loop.
            lv_expect = abap_false.

          ELSEIF ls_n-kind = 'W' OR ls_n-kind = 'Q'.

            " A schema qualification is refused rather than stripped: the
            " allow-list names tables, and a schema is how a system table gets
            " read past a list that never mentioned it.
            IF lv_j < lv_total.
              DATA(ls_after) = it_tokens[ lv_j + 1 ].
              IF ls_after-kind = 'P' AND ls_after-value = '.'.
                es_diag-code = 'SCHEMA_QUALIFIED'.
                es_diag-what = 'Checking the statement.'.
                es_diag-why  = |{ ls_n-value } at position { ls_n-offset } names a schema.|.
                es_diag-fix  = 'Name the table on its own. This tool reads the tables on its list, in this system.'.
                rv_ok = abap_false.
                RETURN.
              ENDIF.
              IF ls_after-kind = 'P' AND ls_after-value = '('.
                es_diag-code = 'TABLE_FUNCTION'.
                es_diag-what = 'Checking the statement.'.
                es_diag-why  = |{ ls_n-value } at position { ls_n-offset } is read as a function, not a table.|.
                es_diag-fix  = 'This tool reads tables and views. Rewrite the query without the function.'.
                rv_ok = abap_false.
                RETURN.
              ENDIF.
            ENDIF.

            CLEAR ls_source.
            ls_source-name   = ls_n-upper.
            ls_source-offset = ls_n-offset.
            ls_source-length = ls_n-length.

            " An alias, with or without AS. A join word is not an alias, or
            " "JOIN marc ON ..." would call the table's alias ON.
            IF lv_j < lv_total.
              DATA(ls_next) = it_tokens[ lv_j + 1 ].
              IF ls_next-kind = 'W' AND ls_next-upper = 'AS' AND lv_j + 1 < lv_total.
                ls_source-alias   = it_tokens[ lv_j + 2 ]-upper.
                ls_source-aliased = abap_true.
                lv_j = lv_j + 2.
              ELSEIF ls_next-kind = 'W'.
                READ TABLE lt_stoppers TRANSPORTING NO FIELDS WITH KEY table_line = ls_next-upper.
                IF sy-subrc <> 0.
                  ls_source-alias   = ls_next-upper.
                  ls_source-aliased = abap_true.
                  lv_j = lv_j + 1.
                ENDIF.
              ENDIF.
            ENDIF.

            IF ls_source-alias IS INITIAL.
              ls_source-alias = ls_source-name.
            ENDIF.

            " A name the WITH clause introduced is not a table.
            READ TABLE it_ctes TRANSPORTING NO FIELDS WITH KEY table_line = ls_source-name.
            IF sy-subrc <> 0.
              APPEND ls_source TO et_sources.
            ENDIF.

            lv_expect = abap_false.

          ELSE.
            es_diag-code = 'UNREADABLE_SOURCE'.
            es_diag-what = 'Checking the statement.'.
            es_diag-why  = |What is read at position { ls_n-offset } could not be identified as a table.|.
            es_diag-fix  = 'Rewrite that part of the FROM clause. A guard that guesses is not a guard, so this one refuses.'.
            rv_ok = abap_false.
            RETURN.

          ENDIF.

        ELSEIF ls_n-depth = lv_depth AND ls_n-kind = 'P' AND ls_n-value = ','.
          " Another source in the same clause -- including one that follows a
          " join condition, which is why ON does not end this scan.
          lv_expect = abap_true.

        ELSEIF ls_n-depth = lv_depth AND ls_n-kind = 'W' AND ls_n-upper = 'JOIN'.
          " Handled by this same LOOP when it reaches that JOIN.
          EXIT.
        ENDIF.

        lv_j = lv_j + 1.

      ENDWHILE.

    ENDLOOP.

  ENDMETHOD.


  METHOD forbidden_words.
    rt_words = VALUE #(
      ( `INSERT` ) ( `UPDATE` ) ( `DELETE` ) ( `MERGE` ) ( `UPSERT` ) ( `REPLACE` )
      ( `TRUNCATE` ) ( `DROP` ) ( `CREATE` ) ( `ALTER` ) ( `RENAME` )
      ( `GRANT` ) ( `REVOKE` ) ( `CALL` ) ( `EXEC` ) ( `EXECUTE` )
      ( `DO` ) ( `BEGIN` ) ( `DECLARE` ) ( `PROCEDURE` ) ( `FUNCTION` ) ( `TRIGGER` )
      ( `COMMIT` ) ( `ROLLBACK` ) ( `SAVEPOINT` ) ( `LOCK` ) ( `UNLOCK` )
      ( `IMPORT` ) ( `EXPORT` ) ( `SET` ) ( `CONNECT` ) ( `DISCONNECT` )
      ( `INTO` ) ( `SCHEMA` ) ( `SYNONYM` ) ( `SEQUENCE` ) ( `SYSTEM` )
      ( `WORKLOAD` ) ( `ADMIN` ) ( `PASSWORD` ) ( `USER` ) ( `ROLE` ) ).
  ENDMETHOD.


  METHOD clause_enders.
    rt_words = VALUE #(
      ( `WHERE` ) ( `GROUP` ) ( `HAVING` ) ( `ORDER` ) ( `LIMIT` ) ( `OFFSET` )
      ( `UNION` ) ( `INTERSECT` ) ( `EXCEPT` ) ( `MINUS` ) ( `WINDOW` )
      ( `FOR` ) ( `WITH` ) ( `SELECT` )
      ( `INNER` ) ( `LEFT` ) ( `RIGHT` ) ( `FULL` ) ( `CROSS` ) ( `OUTER` ) ( `NATURAL` ) ).
  ENDMETHOD.


  METHOD alias_stoppers.
    rt_words = clause_enders( ).
    APPEND `ON` TO rt_words.
    APPEND `USING` TO rt_words.
    APPEND `JOIN` TO rt_words.
  ENDMETHOD.


  METHOD refuse.
    rs_result-ok        = abap_false.
    rs_result-diag-code = iv_code.
    rs_result-diag-what = iv_what.
    rs_result-diag-why  = iv_why.
    rs_result-diag-fix  = iv_fix.
  ENDMETHOD.

ENDCLASS.

