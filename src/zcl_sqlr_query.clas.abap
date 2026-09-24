" Saved queries: keep one, fetch it back, retire it.
"
" Shared by design (spec 036 §3.2). Everyone with execute rights sees the same
" list and may change any of it, which is the right trade for a small team --
" the alternative is the same report retyped by each person who needs it. What
" makes that safe to live with is that nothing is overwritten: each save writes
" a new version and the previous text stays, so "who changed this, and to
" what" has an answer.
"
" Two other decisions worth stating.
"
" **Delete does not delete.** It clears the active flag. A shared list where
" anybody may remove anybody's work needs an undo, and a row that is still
" there is the cheapest one there is. Saving under a retired name brings it
" back, with its history intact.
"
" **The lock is a table lock, not a lock object.** ENQUEUE_E_TABLE on
" ZSQLR_QUERY keyed by the query name does what a generated lock object would
" do here, and needs no object generated to do it -- which matters while this
" lives in $TMP.
CLASS zcl_sqlr_query DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.

    TYPES: BEGIN OF ty_head,
             name       TYPE c LENGTH 30,
             descr      TYPE c LENGTH 60,
             version    TYPE i,
             changed_by TYPE c LENGTH 12,
             changed_at TYPE timestampl,
           END OF ty_head.
    TYPES tt_head TYPE STANDARD TABLE OF ty_head WITH EMPTY KEY.
    TYPES tt_version TYPE STANDARD TABLE OF i WITH EMPTY KEY.

    TYPES: BEGIN OF ty_outcome,
             ok      TYPE abap_bool,
             version TYPE i,
             diag    TYPE zcl_sqlr_guard=>ty_diag,
           END OF ty_outcome.

    "! Every query anyone has saved and not retired.
    CLASS-METHODS list
      RETURNING VALUE(rt_heads) TYPE tt_head.

    "! One query, current version, with its text.
    CLASS-METHODS load
      IMPORTING iv_name      TYPE string
      EXPORTING es_head      TYPE ty_head
                et_text      TYPE rswsourcet
      RETURNING VALUE(rv_ok) TYPE abap_bool.

    "! The text of one particular version, for comparing with what is there now.
    CLASS-METHODS load_version
      IMPORTING iv_name      TYPE string
                iv_version   TYPE i
      EXPORTING et_text      TYPE rswsourcet
      RETURNING VALUE(rv_ok) TYPE abap_bool.

    "! Saves as a new version. The previous text is kept, never overwritten.
    CLASS-METHODS save
      IMPORTING iv_name           TYPE string
                iv_descr          TYPE string
                it_text           TYPE rswsourcet
      RETURNING VALUE(rs_outcome) TYPE ty_outcome.

    "! Retires a query. The rows stay; saving the name again revives it.
    CLASS-METHODS remove
      IMPORTING iv_name           TYPE string
      RETURNING VALUE(rs_outcome) TYPE ty_outcome.

    "! Which versions exist, newest first.
    CLASS-METHODS history
      IMPORTING iv_name            TYPE string
      RETURNING VALUE(rt_versions) TYPE tt_version.

    "! Is this a name a query may have? Pure, and the whole of the rule.
    CLASS-METHODS valid_name
      IMPORTING iv_name           TYPE string
      RETURNING VALUE(rs_outcome) TYPE ty_outcome.

    "! The name as it is stored: upper case, trimmed.
    CLASS-METHODS normalise
      IMPORTING iv_name         TYPE string
      RETURNING VALUE(rv_name)  TYPE string.

  PRIVATE SECTION.

    CONSTANTS c_allowed TYPE string
      VALUE 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_'.

    CLASS-METHODS lock
      IMPORTING iv_name      TYPE string
      RETURNING VALUE(rv_ok) TYPE abap_bool.

    CLASS-METHODS unlock
      IMPORTING iv_name TYPE string.

    CLASS-METHODS refuse
      IMPORTING iv_code           TYPE string
                iv_what           TYPE string
                iv_why            TYPE string
                iv_fix            TYPE string
      RETURNING VALUE(rs_outcome) TYPE ty_outcome.

ENDCLASS.


CLASS zcl_sqlr_query IMPLEMENTATION.

  METHOD normalise.
    rv_name = to_upper( condense( iv_name ) ).
  ENDMETHOD.


  METHOD valid_name.

    DATA(lv_name) = normalise( iv_name ).

    IF lv_name IS INITIAL.
      rs_outcome = refuse(
        iv_code = 'NO_NAME'
        iv_what = 'Saving the query.'
        iv_why  = 'It has no name.'
        iv_fix  = 'Give it a name somebody else would recognise, and save again.' ).
      RETURN.
    ENDIF.

    IF strlen( lv_name ) > 30.
      rs_outcome = refuse(
        iv_code = 'NAME_TOO_LONG'
        iv_what = 'Saving the query.'
        iv_why  = |The name is { strlen( lv_name ) } characters and the field holds 30.|
        iv_fix  = 'Shorten it and save again.' ).
      RETURN.
    ENDIF.

    " Letters, digits and underscore. Not a style rule: the name reaches a
    " background job through a selection screen and a variant, and a name with
    " a space or a comma in it is a name somebody cannot type there.
    DATA(lv_i) = 0.
    WHILE lv_i < strlen( lv_name ).
      IF NOT lv_name+lv_i(1) CA c_allowed.
        rs_outcome = refuse(
          iv_code = 'NAME_NOT_ALLOWED'
          iv_what = 'Saving the query.'
          iv_why  = |The name contains "{ lv_name+lv_i(1) }", which a job variant cannot carry.|
          iv_fix  = 'Use letters, digits and underscores only.' ).
        RETURN.
      ENDIF.
      lv_i = lv_i + 1.
    ENDWHILE.

    rs_outcome-ok = abap_true.

  ENDMETHOD.


  METHOD list.

    SELECT query_name AS name, descr, version, changed_by, changed_at
      FROM zsqlr_query
      WHERE active = @abap_true
      ORDER BY query_name
      INTO CORRESPONDING FIELDS OF TABLE @rt_heads.

  ENDMETHOD.


  METHOD load.

    CLEAR: es_head, et_text.
    DATA(lv_name) = normalise( iv_name ).

    SELECT SINGLE query_name AS name, descr, version, changed_by, changed_at
      FROM zsqlr_query
      WHERE query_name = @lv_name
        AND active     = @abap_true
      INTO CORRESPONDING FIELDS OF @es_head.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    rv_ok = load_version( EXPORTING iv_name    = lv_name
                                    iv_version = es_head-version
                          IMPORTING et_text    = et_text ).

  ENDMETHOD.


  METHOD load_version.

    CLEAR et_text.
    DATA(lv_name) = normalise( iv_name ).

    SELECT line
      FROM zsqlr_qtext
      WHERE query_name = @lv_name
        AND version    = @iv_version
      ORDER BY line_no
      INTO TABLE @DATA(lt_lines).
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    LOOP AT lt_lines INTO DATA(ls_line).
      APPEND INITIAL LINE TO et_text ASSIGNING FIELD-SYMBOL(<lv_line>).
      <lv_line> = ls_line-line.
    ENDLOOP.

    rv_ok = abap_true.

  ENDMETHOD.


  METHOD save.

    DATA(ls_name) = valid_name( iv_name ).
    IF ls_name-ok = abap_false.
      rs_outcome = ls_name.
      RETURN.
    ENDIF.

    DATA(lv_name) = normalise( iv_name ).

    IF it_text IS INITIAL.
      rs_outcome = refuse(
        iv_code = 'NO_TEXT'
        iv_what = 'Saving the query.'
        iv_why  = 'There is no statement to save.'
        iv_fix  = 'Write the statement first, then save it.' ).
      RETURN.
    ENDIF.

    IF lock( lv_name ) = abap_false.
      rs_outcome = refuse(
        iv_code = 'LOCKED'
        iv_what = 'Saving the query.'
        iv_why  = |Somebody else is saving { lv_name } at this moment.|
        iv_fix  = 'Wait for them to finish, then save again.' ).
      RETURN.
    ENDIF.

    GET TIME STAMP FIELD DATA(lv_now).

    SELECT SINGLE version, created_by, created_at
      FROM zsqlr_query
      WHERE query_name = @lv_name
      INTO @DATA(ls_before).

    DATA(lv_version) = COND i( WHEN sy-subrc = 0 THEN ls_before-version + 1 ELSE 1 ).

    DATA ls_head TYPE zsqlr_query.
    ls_head-mandt      = sy-mandt.
    ls_head-query_name = lv_name.
    ls_head-descr      = iv_descr.
    ls_head-active     = abap_true.
    ls_head-version    = lv_version.
    ls_head-created_by = COND #( WHEN ls_before-created_by IS INITIAL THEN sy-uname ELSE ls_before-created_by ).
    ls_head-created_at = COND #( WHEN ls_before-created_at IS INITIAL THEN lv_now ELSE ls_before-created_at ).
    ls_head-changed_by = sy-uname.
    ls_head-changed_at = lv_now.

    DATA lt_text TYPE STANDARD TABLE OF zsqlr_qtext.
    DATA(lv_no) = 0.
    LOOP AT it_text INTO DATA(lv_line).
      lv_no = lv_no + 1.
      APPEND VALUE #( mandt      = sy-mandt
                      query_name = lv_name
                      version    = lv_version
                      line_no    = lv_no
                      line       = lv_line ) TO lt_text.
    ENDLOOP.

    " The new version's lines first, then the header that points at them: a
    " header naming a version whose text is not there yet is a query that
    " cannot be opened, and the window for it should be nil rather than small.
    INSERT zsqlr_qtext FROM TABLE lt_text.
    MODIFY zsqlr_query FROM ls_head.
    COMMIT WORK AND WAIT.

    unlock( lv_name ).

    rs_outcome-ok      = abap_true.
    rs_outcome-version = lv_version.

  ENDMETHOD.


  METHOD remove.

    DATA(lv_name) = normalise( iv_name ).

    SELECT SINGLE query_name FROM zsqlr_query
      WHERE query_name = @lv_name AND active = @abap_true
      INTO @DATA(lv_found).
    IF sy-subrc <> 0.
      rs_outcome = refuse(
        iv_code = 'NOT_FOUND'
        iv_what = 'Retiring the query.'
        iv_why  = |There is no saved query called { lv_name }.|
        iv_fix  = 'Check the name against the list of saved queries.' ).
      RETURN.
    ENDIF.

    IF lock( lv_name ) = abap_false.
      rs_outcome = refuse(
        iv_code = 'LOCKED'
        iv_what = 'Retiring the query.'
        iv_why  = |Somebody else is working on { lv_name } at this moment.|
        iv_fix  = 'Wait for them to finish, then try again.' ).
      RETURN.
    ENDIF.

    GET TIME STAMP FIELD DATA(lv_now).
    UPDATE zsqlr_query
      SET active     = @abap_false,
          changed_by = @sy-uname,
          changed_at = @lv_now
      WHERE query_name = @lv_name.
    COMMIT WORK AND WAIT.

    unlock( lv_name ).
    rs_outcome-ok = abap_true.

  ENDMETHOD.


  METHOD history.

    DATA(lv_name) = normalise( iv_name ).

    SELECT DISTINCT version
      FROM zsqlr_qtext
      WHERE query_name = @lv_name
      ORDER BY version DESCENDING
      INTO TABLE @DATA(lt_found).

    LOOP AT lt_found INTO DATA(ls_found).
      APPEND ls_found-version TO rt_versions.
    ENDLOOP.

  ENDMETHOD.


  METHOD lock.

    " Typed exactly as the function module declares them, and not a literal
    " among them. A generic CONV here dumps with CALL_FUNCTION_CONFLICT_TYPE
    " -- which is what it did, and what it did the last time somebody in this
    " programme passed a convenient type to a classic function module.
    DATA lv_mode    TYPE dd26e-enqmode   VALUE 'E'.
    DATA lv_tabname TYPE rstable-tabname VALUE 'ZSQLR_QUERY'.
    DATA lv_varkey  TYPE rstable-varkey.

    lv_varkey = iv_name.

    CALL FUNCTION 'ENQUEUE_E_TABLE'
      EXPORTING
        mode_rstable   = lv_mode
        tabname        = lv_tabname
        varkey         = lv_varkey
      EXCEPTIONS
        foreign_lock   = 1
        system_failure = 2
        OTHERS         = 3.

    rv_ok = xsdbool( sy-subrc = 0 ).

  ENDMETHOD.


  METHOD unlock.

    DATA lv_mode    TYPE dd26e-enqmode   VALUE 'E'.
    DATA lv_tabname TYPE rstable-tabname VALUE 'ZSQLR_QUERY'.
    DATA lv_varkey  TYPE rstable-varkey.

    lv_varkey = iv_name.

    CALL FUNCTION 'DEQUEUE_E_TABLE'
      EXPORTING
        mode_rstable = lv_mode
        tabname      = lv_tabname
        varkey       = lv_varkey.

  ENDMETHOD.


  METHOD refuse.
    rs_outcome-ok        = abap_false.
    rs_outcome-diag-code = iv_code.
    rs_outcome-diag-what = iv_what.
    rs_outcome-diag-why  = iv_why.
    rs_outcome-diag-fix  = iv_fix.
  ENDMETHOD.

ENDCLASS.

