" Running the statement, and catching what comes back.
"
" ADBC hands rows to a table the caller supplies, and the columns are not
" known until the database has parsed the statement -- which is the awkward
" part of a tool that must display any query. CL_SQL_RESULT_SET answers it:
" get_metadata describes the columns and get_struct_ref builds a structure
" from that description, including the decimal, decfloat and timestamp
" cases. That was an open question in spec 037 section 2.1 and it is
" closed: SAP's own class does it.
"
" Fetching is package by package. The caller decides how much it wants -- an
" ALV wants everything and has a cap for it; a CSV writer wants one package
" at a time and has no cap at all, because it never holds more than one.
"
" One connection, taken in one place. Spec 037 section 2.2: HANA refuses
" SET TRANSACTION READ ONLY here and accepts a write through this
" connection, so the guard is the only protection. When a SELECT-only
" database user is created, connection( ) is the single line that changes.
CLASS zcl_sqlr_exec DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.

    TYPES: BEGIN OF ty_column,
             name     TYPE string,
             type     TYPE string,
             length   TYPE i,
             decimals TYPE i,
           END OF ty_column.
    TYPES tt_column TYPE STANDARD TABLE OF ty_column WITH EMPTY KEY.

    TYPES: BEGIN OF ty_result,
             ok        TYPE abap_bool,
             columns   TYPE tt_column,
             " The rows, as a table whose line type is the query's own shape.
             data      TYPE REF TO data,
             rows      TYPE i,
             " True when the cap stopped the fetch before the result did.
             truncated TYPE abap_bool,
             diag      TYPE zcl_sqlr_guard=>ty_diag,
           END OF ty_result.

    CONSTANTS c_package TYPE i VALUE 10000.

    "! Is this statement one the database will accept, and what does it return?
    "!
    "! The cursor is opened and **no row is fetched**. That is not the obvious
    "! way round: preparing the statement looks cheaper and is what this first
    "! did. It does not work here -- ADBC's prepare accepted
    "! SELECT no_such_column FROM mara without complaint, and the run then
    "! failed on it. A check that passes what the run refuses is worse than no
    "! check, so this asks the question that actually gets answered.
    CLASS-METHODS describe
      IMPORTING iv_sql           TYPE string
      RETURNING VALUE(rs_result) TYPE ty_result.

    "! Runs it, fetching in packages.
    "! @parameter iv_max_rows | 0 for everything. Above the cap the result is
    "!                          returned truncated rather than refused, and
    "!                          says so, so a caller can show what it has.
    CLASS-METHODS run
      IMPORTING iv_sql           TYPE string
                iv_max_rows      TYPE i DEFAULT 0
      RETURNING VALUE(rs_result) TYPE ty_result.

    "! Runs it and hands each package straight on, keeping none of them.
    "!
    "! This is the method that makes the size promise in spec 036 section 6
    "! true. run( ) builds the complete answer before anyone sees it, which
    "! is what a grid needs and what a file must not need: a sink writes
    "! each package and forgets it, so the extract is bounded by the disk it
    "! is going to rather than by this work process.
    "!
    "! rs_result-data stays empty. The rows went to the sink.
    CLASS-METHODS stream
      IMPORTING iv_sql           TYPE string
                io_sink          TYPE REF TO zif_sqlr_sink
                iv_max_rows      TYPE i DEFAULT 0
      RETURNING VALUE(rs_result) TYPE ty_result.

  PRIVATE SECTION.

    CLASS-METHODS connection
      RETURNING VALUE(ro_con) TYPE REF TO cl_sql_connection
      RAISING   cx_sql_exception.

    CLASS-METHODS columns_of
      IMPORTING it_md            TYPE adbc_rs_metadata_descr_tab
      RETURNING VALUE(rt_column) TYPE tt_column.

    CLASS-METHODS failed
      IMPORTING iv_what          TYPE string
                iv_why           TYPE string
                iv_fix           TYPE string
                iv_code          TYPE string DEFAULT 'DB_ERROR'
      RETURNING VALUE(rs_result) TYPE ty_result.

ENDCLASS.


CLASS zcl_sqlr_exec IMPLEMENTATION.

  METHOD connection.
    " The one place. A restricted user arrives here or nowhere.
    ro_con = cl_sql_connection=>get_connection( ).
  ENDMETHOD.


  METHOD describe.

    DATA lo_res TYPE REF TO cl_sql_result_set.

    TRY.
        DATA(lo_con)  = connection( ).
        DATA(lo_stmt) = lo_con->create_statement( ).

        " Opened, described, closed. The database parses the statement and
        " resolves every name to answer this, which is exactly the question
        " the check is asking; nothing is fetched, so no result is built.
        lo_res = lo_stmt->execute_query( iv_sql ).
        rs_result-columns = columns_of( lo_res->get_metadata( ) ).
        lo_res->close( ).
        lo_con->rollback( ).

        rs_result-ok = abap_true.

      CATCH cx_sql_exception INTO DATA(lx).
        rs_result = failed(
          iv_what = 'Checking the statement against the database.'
          iv_why  = lx->get_text( )
          iv_fix  = 'The database parsed it and refused. Correct the statement and check again.' ).

      CATCH cx_root INTO DATA(lx_any).
        rs_result = failed(
          iv_code = 'UNEXPECTED'
          iv_what = 'Checking the statement against the database.'
          iv_why  = lx_any->get_text( )
          iv_fix  = 'Nothing here can act on this. Keep the message and tell whoever maintains the tool.' ).
    ENDTRY.

  ENDMETHOD.


  METHOD run.

    DATA lo_res     TYPE REF TO cl_sql_result_set.
    DATA lr_package TYPE REF TO data.
    DATA lr_all     TYPE REF TO data.
    FIELD-SYMBOLS <lt_package> TYPE STANDARD TABLE.
    FIELD-SYMBOLS <lt_all>     TYPE STANDARD TABLE.

    TRY.
        DATA(lo_con)  = connection( ).
        DATA(lo_stmt) = lo_con->create_statement( ).
        lo_res = lo_stmt->execute_query( iv_sql ).

        DATA(lt_md) = lo_res->get_metadata( ).
        rs_result-columns = columns_of( lt_md ).

        " The line type is the query's own shape, built by SAP's own mapping
        " rather than a table of type codes maintained here.
        DATA(lr_line) = lo_res->get_struct_ref( md_tab = lt_md ).
        DATA(lo_line) = CAST cl_abap_structdescr( cl_abap_typedescr=>describe_by_data_ref( lr_line ) ).
        DATA(lo_tab)  = cl_abap_tabledescr=>create( p_line_type = lo_line ).

        CREATE DATA lr_package TYPE HANDLE lo_tab.
        CREATE DATA lr_all     TYPE HANDLE lo_tab.
        ASSIGN lr_package->* TO <lt_package>.
        ASSIGN lr_all->*     TO <lt_all>.

        lo_res->set_param_table( lr_package ).

        " How much to ask for at a time. Never more than what is still wanted,
        " so a cap of 10 rows does not fetch 10,000 to throw 9,990 away.
        DATA(lv_package) = c_package.
        IF iv_max_rows > 0 AND iv_max_rows < lv_package.
          lv_package = iv_max_rows.
        ENDIF.

        DO.
          DATA(lv_got) = lo_res->next_package( upto = lv_package ).
          IF lv_got = 0.
            EXIT.
          ENDIF.
          APPEND LINES OF <lt_package> TO <lt_all>.

          IF iv_max_rows > 0 AND lines( <lt_all> ) >= iv_max_rows.
            " There may be more. Whether there is, is the caller's business:
            " it is the difference between "here is the answer" and "here is
            " the first part of it", and a screen must not say the first when
            " it means the second.
            DELETE <lt_all> FROM iv_max_rows + 1.
            rs_result-truncated = xsdbool( lv_got = lv_package ).
            EXIT.
          ENDIF.
        ENDDO.

        lo_res->close( ).

        " Nothing is committed here, ever. A read needs no commit, and a tool
        " that cannot write has nothing to commit.
        lo_con->rollback( ).

        rs_result-data = lr_all.
        rs_result-rows = lines( <lt_all> ).
        rs_result-ok   = abap_true.

      CATCH cx_sql_exception INTO DATA(lx).
        rs_result = failed(
          iv_what = 'Running the statement.'
          iv_why  = lx->get_text( )
          iv_fix  = 'The database refused it while running. Check the statement, then try a smaller range.' ).

      CATCH cx_root INTO DATA(lx_any).
        rs_result = failed(
          iv_code = 'UNEXPECTED'
          iv_what = 'Running the statement.'
          iv_why  = lx_any->get_text( )
          iv_fix  = 'Nothing here can act on this. Keep the message and tell whoever maintains the tool.' ).
    ENDTRY.

  ENDMETHOD.


  METHOD stream.

    DATA lo_res     TYPE REF TO cl_sql_result_set.
    DATA lr_package TYPE REF TO data.
    DATA ls_sink    TYPE zcl_sqlr_guard=>ty_diag.
    FIELD-SYMBOLS <lt_package> TYPE STANDARD TABLE.

    TRY.
        DATA(lo_con)  = connection( ).
        DATA(lo_stmt) = lo_con->create_statement( ).
        lo_res = lo_stmt->execute_query( iv_sql ).

        DATA(lt_md) = lo_res->get_metadata( ).
        rs_result-columns = columns_of( lt_md ).

        DATA(lr_line) = lo_res->get_struct_ref( md_tab = lt_md ).
        DATA(lo_line) = CAST cl_abap_structdescr( cl_abap_typedescr=>describe_by_data_ref( lr_line ) ).
        DATA(lo_tab)  = cl_abap_tabledescr=>create( p_line_type = lo_line ).

        " One package, reused. That is the whole difference from run( ).
        CREATE DATA lr_package TYPE HANDLE lo_tab.
        ASSIGN lr_package->* TO <lt_package>.
        lo_res->set_param_table( lr_package ).

        " The empty row carries the column names, and nothing else: a sink
        " writes its header before the database has returned a single row.
        io_sink->open( lr_line ).
        ls_sink = io_sink->failure( ).
        IF ls_sink-code IS NOT INITIAL.
          lo_res->close( ).
          lo_con->rollback( ).
          io_sink->close( ).
          rs_result-diag = ls_sink.
          RETURN.
        ENDIF.

        DATA(lv_package) = c_package.
        IF iv_max_rows > 0 AND iv_max_rows < lv_package.
          lv_package = iv_max_rows.
        ENDIF.

        DO.
          DATA(lv_got) = lo_res->next_package( upto = lv_package ).
          IF lv_got = 0.
            EXIT.
          ENDIF.

          IF iv_max_rows > 0 AND rs_result-rows + lv_got >= iv_max_rows.
            DATA(lv_keep) = iv_max_rows - rs_result-rows.
            IF lv_keep < lv_got.
              DELETE <lt_package> FROM lv_keep + 1.
            ENDIF.
            rs_result-rows      = rs_result-rows + lines( <lt_package> ).
            rs_result-truncated = xsdbool( lv_got = lv_package ).
            io_sink->write( lr_package ).
            EXIT.
          ENDIF.

          rs_result-rows = rs_result-rows + lv_got.
          io_sink->write( lr_package ).

          " Asked between packages, not at the end. A disk that fills up on
          " the second package should stop the fetch there rather than be
          " discovered after the other nine hundred have been read.
          ls_sink = io_sink->failure( ).
          IF ls_sink-code IS NOT INITIAL.
            EXIT.
          ENDIF.
        ENDDO.

        lo_res->close( ).
        lo_con->rollback( ).
        io_sink->close( ).

        ls_sink = io_sink->failure( ).
        IF ls_sink-code IS NOT INITIAL.
          rs_result-diag = ls_sink.
          RETURN.
        ENDIF.

        rs_result-ok = abap_true.

      CATCH cx_sql_exception INTO DATA(lx).
        io_sink->close( ).
        rs_result = failed(
          iv_what = 'Running the statement into a file.'
          iv_why  = lx->get_text( )
          iv_fix  = 'The database refused it while running. Check the statement, then try a smaller range.' ).

      CATCH cx_root INTO DATA(lx_any).
        io_sink->close( ).
        rs_result = failed(
          iv_code = 'UNEXPECTED'
          iv_what = 'Running the statement into a file.'
          iv_why  = lx_any->get_text( )
          iv_fix  = 'Nothing here can act on this. Keep the message and tell whoever maintains the tool.' ).
    ENDTRY.

  ENDMETHOD.


  METHOD columns_of.
    LOOP AT it_md INTO DATA(ls_md).
      APPEND VALUE #( name     = ls_md-column_name
                      type     = ls_md-data_type
                      length   = ls_md-length
                      decimals = ls_md-decimals ) TO rt_column.
    ENDLOOP.
  ENDMETHOD.


  METHOD failed.
    rs_result-ok        = abap_false.
    rs_result-diag-code = iv_code.
    rs_result-diag-what = iv_what.
    rs_result-diag-why  = iv_why.
    rs_result-diag-fix  = iv_fix.
  ENDMETHOD.

ENDCLASS.
