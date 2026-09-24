" One client's rows, whether or not the author remembered to ask for them.
"
" Native SQL sees every client in the table. A reporting tool that hands that
" to an analyst produces figures that are silently too big -- three clients of
" material masters added together look exactly like one client with more
" materials. So the restriction is applied by the tool, not left to the author,
" and running without it needs a separate authorisation (spec 036 §4.3).
"
" How, and why this way. The obvious approach -- add MANDT = '250' to the WHERE
" clause -- means understanding the WHERE clause: an OR at the top level turns
" the added condition into a no-op, and getting bracket precedence right on
" somebody else's SQL, every time, is not a bet worth taking. So each
" client-dependent table is replaced by a derived table that carries its own
" restriction:
"
"   FROM mara AS a   ->   FROM (SELECT * FROM mara WHERE mandt = '250') AS a
"
" The restriction travels with the table wherever it is used -- in a subquery,
" in a UNION branch, in a join condition's table -- and the outer WHERE cannot
" undo it. Every column reference in the rest of the statement still resolves,
" because the derived table keeps the name the author used.
"
" The rewriting half is pure: it takes the sources, the client-dependent list
" and the client, and returns text. Which tables are client-dependent is a
" dictionary question, answered separately, so the rules can be tested without
" a database.
CLASS zcl_sqlr_client DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.

    " A table and the column that holds its client. Not always MANDT: some
    " dictionary tables call it MANDANT, and a rewrite naming the wrong column
    " fails at the database rather than silently, which is the right failure
    " but still a failure.
    TYPES: BEGIN OF ty_clientdep,
             name  TYPE string,
             field TYPE string,
           END OF ty_clientdep.
    TYPES tt_clientdep TYPE STANDARD TABLE OF ty_clientdep WITH EMPTY KEY.

    "! The statement, with every client-dependent source restricted.
    "! Pure: give it the sources, the client-dependent tables and the client.
    CLASS-METHODS rewrite
      IMPORTING iv_sql        TYPE string
                it_sources    TYPE zcl_sqlr_guard=>tt_source
                it_clientdep  TYPE tt_clientdep
                iv_client     TYPE symandt
      RETURNING VALUE(rv_sql) TYPE string.

    "! Which of these sources carry a client, asked of the dictionary.
    "! A table whose first key field is MANDT or MANDANT is client-dependent;
    "! anything else is the same in every client and needs no restriction.
    CLASS-METHODS client_dependent
      IMPORTING it_sources       TYPE zcl_sqlr_guard=>tt_source
      RETURNING VALUE(rt_result) TYPE tt_clientdep.

    "! What the running tool calls: look up, then rewrite, for this client.
    CLASS-METHODS for_current_client
      IMPORTING iv_sql        TYPE string
                it_sources    TYPE zcl_sqlr_guard=>tt_source
      RETURNING VALUE(rv_sql) TYPE string.

ENDCLASS.


CLASS zcl_sqlr_client IMPLEMENTATION.

  METHOD rewrite.

    rv_sql = iv_sql.

    IF it_sources IS INITIAL OR it_clientdep IS INITIAL.
      RETURN.
    ENDIF.

    " Back to front. Every splice changes the length of the text, so an offset
    " taken before it is only still true for the parts in front of it.
    DATA(lt_sorted) = it_sources.
    SORT lt_sorted BY offset DESCENDING.

    LOOP AT lt_sorted INTO DATA(ls_source).

      READ TABLE it_clientdep INTO DATA(ls_dep) WITH KEY name = ls_source-name.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.

      " The name exactly as the author wrote it, quotes, namespace and all.
      " Re-spelling it here is how a quoted identifier stops resolving.
      DATA(lv_written) = substring( val = rv_sql off = ls_source-offset len = ls_source-length ).

      DATA(lv_derived) = |(SELECT * FROM { lv_written } WHERE { ls_dep-field } = '{ iv_client }')|.

      " A derived table has to be called something. When the author wrote an
      " alias it is still there, right after the name we are replacing, and
      " adding a second one would be a syntax error; when they did not, the
      " table's own name takes its place, so the rest of the statement still
      " resolves.
      IF ls_source-aliased = abap_false.
        lv_derived = |{ lv_derived } { ls_source-alias }|.
      ENDIF.

      rv_sql = substring( val = rv_sql len = ls_source-offset )
            && lv_derived
            && substring( val = rv_sql off = ls_source-offset + ls_source-length ).

    ENDLOOP.

  ENDMETHOD.


  METHOD client_dependent.

    IF it_sources IS INITIAL.
      RETURN.
    ENDIF.

    DATA lt_names TYPE STANDARD TABLE OF tabname.
    LOOP AT it_sources INTO DATA(ls_source).
      APPEND CONV tabname( ls_source-name ) TO lt_names.
    ENDLOOP.
    SORT lt_names.
    DELETE ADJACENT DUPLICATES FROM lt_names.

    " The first key field decides it. A MANDT somewhere in the middle of a
    " table is a column that happens to be called MANDT, not a client.
    SELECT tabname, fieldname
      FROM dd03l
      FOR ALL ENTRIES IN @lt_names
      WHERE tabname  = @lt_names-table_line
        AND position = '0001'
        AND keyflag  = 'X'
        AND as4local = 'A'
        AND ( fieldname = 'MANDT' OR fieldname = 'MANDANT' )
      INTO TABLE @DATA(lt_found).

    LOOP AT lt_found INTO DATA(ls_found).
      APPEND VALUE #( name  = CONV string( ls_found-tabname )
                      field = CONV string( ls_found-fieldname ) ) TO rt_result.
    ENDLOOP.

  ENDMETHOD.


  METHOD for_current_client.

    rv_sql = rewrite( iv_sql       = iv_sql
                      it_sources   = it_sources
                      it_clientdep = client_dependent( it_sources )
                      iv_client    = sy-mandt ).

  ENDMETHOD.

ENDCLASS.

