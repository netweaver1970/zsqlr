" Who pulled that extract -- in SLG1, where logs belong.
"
" This was a table of its own for about an hour. It should not have
" been: SAP has an application log, everybody who reads logs already
" knows SLG1, and a custom table means a custom viewer, a custom
" retention rule and a custom authorisation nobody else's tooling knows
" about. Object ZSQLR, subobject RUN.
"
" The shape of the old one is kept, and it is worth keeping: a run
" accumulates into ty_run as it goes, and **nothing is written until it
" ends**. That falls out of BAL for free -- BAL_LOG_CREATE builds the log
" in memory and only BAL_DB_SAVE touches the database -- so the log is
" still written once, at the end, and there is still no update path.
"
" A run that dumps or is killed leaves no entry. That is the same trade
" as before: what is being recorded is data leaving the system, and a run
" that died delivered nothing.
"
" Refusals are logged, and they are the half that matters: a statement
" naming a payroll table is worth knowing about precisely because it was
" refused. They come out as warnings, so SLG1's traffic lights point at
" them.
CLASS zcl_sqlr_log DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.

    CONSTANTS c_object    TYPE balobj_d  VALUE 'ZSQLR'.
    CONSTANTS c_subobject TYPE balsubobj VALUE 'RUN'.

    " Every change to who may read which tables (ZSQLR_GRANT), kept apart
    " from the runs so an auditor asking about grants is not wading through
    " a day's queries to find them. Required for audit since 24 Sept 2026.
    CONSTANTS c_sub_grant TYPE balsubobj VALUE 'GRANT'.

    CONSTANTS: c_done    TYPE c LENGTH 1 VALUE 'S',
               c_refused TYPE c LENGTH 1 VALUE 'R',
               c_nothing TYPE c LENGTH 1 VALUE 'N'.

    " Everything a run accumulates on its way through. The screen fills
    " it as it goes and hands it back at the end.
    TYPES: BEGIN OF ty_run,
             started_at  TYPE timestampl,
             query_name  TYPE c LENGTH 30,
             target      TYPE c LENGTH 10,
             out_format  TYPE c LENGTH 4,
             client_mode TYPE c LENGTH 1,
             where_to    TYPE c LENGTH 128,
             statement   TYPE string,
             rows        TYPE int8,
             bytes       TYPE int8,
             truncated   TYPE abap_bool,
             outcome     TYPE c LENGTH 1,
             code        TYPE c LENGTH 30,
             message     TYPE c LENGTH 255,
           END OF ty_run.

    " Opens a run. Writes nothing, and creates nothing: the log itself is
    " built at the end, when there is something to say in its header.
    CLASS-METHODS begin
      RETURNING VALUE(rs_run) TYPE ty_run.

    " Closes it. Never raises and never refuses: a tool that falls over
    " because its log did is worse than one that runs unlogged for an
    " afternoon.
    CLASS-METHODS finish
      IMPORTING is_run TYPE ty_run.

    " The audit entry for one save of the grant lists.
    "
    " Unlike finish( ), this does not commit and it does report failure,
    " both deliberately. The caller commits the entry together with the
    " change it records, in one LUW, so there is never a change without its
    " entry or an entry for a change that was rolled back -- and a change
    " that cannot be recorded is not made.
    CLASS-METHODS grants_changed
      IMPORTING iv_headline TYPE string
                it_lines    TYPE string_table
      RETURNING VALUE(rv_ok) TYPE abap_bool.

    " SLG1, already filtered on this tool. The button on the screen and
    " transaction ZSQLR_LOG both come here: the runs by default, the
    " grant changes when asked.
    CLASS-METHODS show
      IMPORTING iv_from      TYPE d OPTIONAL
                iv_user      TYPE xubname OPTIONAL
                iv_subobject TYPE balsubobj DEFAULT c_subobject.

  PRIVATE SECTION.

    " BAL_LOG_MSG_ADD_FREE_TEXT takes four SYMSGV fields and cuts what
    " does not fit, silently. Splitting here rather than being cut there
    " is the difference between a long statement being readable in SLG1
    " and ending mid-word.
    CONSTANTS c_width TYPE i VALUE 200.

    CLASS-METHODS add
      IMPORTING iv_handle TYPE balloghndl
                iv_type   TYPE symsgty
                iv_level  TYPE ballevel
                iv_text   TYPE string
                iv_class  TYPE balprobcl DEFAULT '4'.

ENDCLASS.


CLASS zcl_sqlr_log IMPLEMENTATION.

  METHOD begin.
    GET TIME STAMP FIELD rs_run-started_at.
  ENDMETHOD.


  METHOD finish.

    " A run that never began is a screen action that was not a run --
    " opening a query, looking at the table list. Nothing to record.
    IF is_run-started_at IS INITIAL.
      RETURN.
    ENDIF.

    DATA ls_log    TYPE bal_s_log.
    DATA lv_handle TYPE balloghndl.

    ls_log-object    = c_object.
    ls_log-subobject = c_subobject.
    ls_log-aldate    = sy-datum.
    ls_log-altime    = sy-uzeit.
    ls_log-aluser    = sy-uname.
    ls_log-alprog    = sy-repid.
    ls_log-altcode   = sy-tcode.

    " What SLG1 shows in its list before anybody opens anything, so it
    " has to say which query went where.
    ls_log-extnumber = |{ COND string( WHEN is_run-query_name IS INITIAL
                                       THEN `(unnamed)`
                                       ELSE is_run-query_name ) } | &&
                       |-> { is_run-target }|.

    CALL FUNCTION 'BAL_LOG_CREATE'
      EXPORTING
        i_s_log                 = ls_log
      IMPORTING
        e_log_handle            = lv_handle
      EXCEPTIONS
        log_header_inconsistent = 1
        OTHERS                  = 2.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    " --- the headline -------------------------------------------------

    DATA(lv_type)  = SWITCH symsgty( is_run-outcome
                                     WHEN c_done    THEN 'S'
                                     WHEN c_refused THEN 'W'
                                     ELSE                'I' ).

    " A refusal is "important" rather than "additional information", so
    " that somebody filtering SLG1 by problem class finds the attempts
    " without reading every successful extract.
    DATA(lv_class) = COND balprobcl( WHEN is_run-outcome = c_refused THEN '2' ELSE '4' ).

    DATA(lv_head) = SWITCH string( is_run-outcome
      WHEN c_done    THEN |{ is_run-rows } row(s) to { is_run-target }|
      WHEN c_refused THEN |Refused: { is_run-code }|
      ELSE                |Ran, and returned no rows| ).

    add( iv_handle = lv_handle iv_type = lv_type iv_level = '1'
         iv_class = lv_class iv_text = lv_head ).

    " --- what happened, one level down --------------------------------

    IF is_run-message IS NOT INITIAL.
      add( iv_handle = lv_handle iv_type = lv_type iv_level = '2'
           iv_class = lv_class iv_text = CONV string( is_run-message ) ).
    ENDIF.

    DATA(lv_where) = |Destination { is_run-target }| &&
                     COND string( WHEN is_run-out_format IS NOT INITIAL
                                  THEN | as { is_run-out_format }| ) &&
                     COND string( WHEN is_run-where_to IS NOT INITIAL
                                  THEN |, to { is_run-where_to }| ).
    add( iv_handle = lv_handle iv_type = 'I' iv_level = '2' iv_text = lv_where ).

    IF is_run-bytes > 0.
      add( iv_handle = lv_handle iv_type = 'I' iv_level = '2'
           iv_text = |{ is_run-bytes } bytes| ).
    ENDIF.

    IF is_run-truncated = abap_true.
      " Not a detail. A capped extract that does not say so is how
      " somebody reports a wrong total.
      add( iv_handle = lv_handle iv_type = 'W' iv_level = '2' iv_class = '2'
           iv_text = |Capped: this is the first { is_run-rows } rows, not all of them| ).
    ENDIF.

    add( iv_handle = lv_handle iv_type = 'I' iv_level = '2'
         iv_text = COND string( WHEN is_run-client_mode = 'X'
                                THEN `Read every client`
                                ELSE |Read client { sy-mandt } only| ) ).

    " --- and the statement, as it was sent ----------------------------

    IF is_run-statement IS NOT INITIAL.
      add( iv_handle = lv_handle iv_type = 'I' iv_level = '2'
           iv_text = `The statement, as it was sent:` ).

      SPLIT is_run-statement AT cl_abap_char_utilities=>newline INTO TABLE DATA(lt_lines).
      LOOP AT lt_lines INTO DATA(lv_line).
        add( iv_handle = lv_handle iv_type = 'I' iv_level = '3' iv_text = lv_line ).
      ENDLOOP.
    ENDIF.

    " --- and only now does anything reach the database ----------------

    CALL FUNCTION 'BAL_DB_SAVE'
      EXPORTING
        i_t_log_handle   = VALUE bal_t_logh( ( lv_handle ) )
      EXCEPTIONS
        log_not_found    = 1
        save_not_allowed = 2
        numbering_error  = 3
        OTHERS           = 4.

    IF sy-subrc = 0.
      COMMIT WORK.
    ELSE.
      ROLLBACK WORK.
    ENDIF.

  ENDMETHOD.


  METHOD grants_changed.

    DATA ls_log    TYPE bal_s_log.
    DATA lv_handle TYPE balloghndl.

    ls_log-object    = c_object.
    ls_log-subobject = c_sub_grant.
    ls_log-aldate    = sy-datum.
    ls_log-altime    = sy-uzeit.
    ls_log-aluser    = sy-uname.
    ls_log-alprog    = sy-repid.
    ls_log-altcode   = sy-tcode.
    ls_log-extnumber = |Table lists, changed by { sy-uname }|.

    " Fails when the subobject is not defined, which is exactly the case
    " where saving must stop.
    CALL FUNCTION 'BAL_LOG_CREATE'
      EXPORTING
        i_s_log                 = ls_log
      IMPORTING
        e_log_handle            = lv_handle
      EXCEPTIONS
        log_header_inconsistent = 1
        OTHERS                  = 2.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    " The headline is "important", so a filter on problem class in SLG1
    " finds grant changes without knowing to look for them.
    add( iv_handle = lv_handle iv_type = 'S' iv_level = '1'
         iv_text = iv_headline iv_class = '2' ).

    LOOP AT it_lines INTO DATA(lv_line).
      add( iv_handle = lv_handle iv_type = 'I' iv_level = '2' iv_text = lv_line ).
    ENDLOOP.

    " Into the database, not yet committed: the caller's COMMIT WORK takes
    " this and the grant change together, or its ROLLBACK takes neither.
    CALL FUNCTION 'BAL_DB_SAVE'
      EXPORTING
        i_t_log_handle   = VALUE bal_t_logh( ( lv_handle ) )
      EXCEPTIONS
        log_not_found    = 1
        save_not_allowed = 2
        numbering_error  = 3
        OTHERS           = 4.

    rv_ok = xsdbool( sy-subrc = 0 ).

  ENDMETHOD.


  METHOD add.

    " Split rather than let BAL cut. Long lines are wrapped and the rest
    " carried on at the same level, so a statement stays readable.
    DATA lv_rest TYPE string.
    DATA lv_part TYPE c LENGTH 200.

    lv_rest = iv_text.
    IF lv_rest IS INITIAL.
      RETURN.
    ENDIF.

    WHILE lv_rest IS NOT INITIAL.

      lv_part = lv_rest.

      IF strlen( lv_rest ) > c_width.
        lv_rest = substring( val = lv_rest off = c_width ).
      ELSE.
        CLEAR lv_rest.
      ENDIF.

      CALL FUNCTION 'BAL_LOG_MSG_ADD_FREE_TEXT'
        EXPORTING
          i_log_handle     = iv_handle
          i_msgty          = iv_type
          i_probclass      = iv_class
          i_text           = lv_part
          i_detlevel       = iv_level
        EXCEPTIONS
          log_not_found    = 1
          msg_inconsistent = 2
          log_is_full      = 3
          OTHERS           = 4.

      IF sy-subrc <> 0.
        RETURN.
      ENDIF.

    ENDWHILE.

  ENDMETHOD.


  METHOD show.

    " Declared, not inlined: a classic CALL FUNCTION will not take an
    " inline declaration in an IMPORTING parameter.
    DATA ls_filter  TYPE bal_s_lfil.
    DATA lt_header  TYPE balhdr_t.
    DATA lt_handle  TYPE bal_t_logh.
    DATA ls_profile TYPE bal_s_prof.

    ls_filter-object    = VALUE #( ( sign = 'I' option = 'EQ' low = c_object ) ).
    ls_filter-subobject = VALUE #( ( sign = 'I' option = 'EQ' low = iv_subobject ) ).

    IF iv_from IS NOT INITIAL.
      ls_filter-aldate = VALUE #( ( sign = 'I' option = 'GE' low = iv_from ) ).
    ENDIF.

    IF iv_user IS NOT INITIAL.
      ls_filter-aluser = VALUE #( ( sign = 'I' option = 'EQ' low = iv_user ) ).
    ENDIF.

    CALL FUNCTION 'BAL_DB_SEARCH'
      EXPORTING
        i_s_log_filter     = ls_filter
      IMPORTING
        e_t_log_header     = lt_header
      EXCEPTIONS
        log_not_found      = 1
        no_filter_criteria = 2
        OTHERS             = 3.

    IF sy-subrc <> 0 OR lt_header IS INITIAL.
      MESSAGE COND string( WHEN iv_subobject = c_sub_grant
                           THEN `No table list has been changed in that period.`
                           ELSE `Nothing has been run in that period.` ) TYPE 'S'.
      RETURN.
    ENDIF.

    CALL FUNCTION 'BAL_DB_LOAD'
      EXPORTING
        i_t_log_header     = lt_header
      IMPORTING
        e_t_log_handle     = lt_handle
      EXCEPTIONS
        no_logs_specified  = 1
        log_not_found      = 2
        log_already_loaded = 3
        OTHERS             = 4.

    CALL FUNCTION 'BAL_DSP_PROFILE_STANDARD_GET'
      IMPORTING
        e_s_display_profile = ls_profile.

    CALL FUNCTION 'BAL_DSP_LOG_DISPLAY'
      EXPORTING
        i_s_display_profile  = ls_profile
        i_s_log_filter       = ls_filter
      EXCEPTIONS
        profile_inconsistent = 1
        internal_error       = 2
        no_data_available    = 3
        no_authority         = 4
        OTHERS               = 5.

    IF sy-subrc = 3.
      MESSAGE COND string( WHEN iv_subobject = c_sub_grant
                           THEN `No table list has been changed in that period.`
                           ELSE `Nothing has been run in that period.` ) TYPE 'S'.
    ELSEIF sy-subrc <> 0.
      MESSAGE |The log could not be shown, subrc { sy-subrc }.| TYPE 'S' DISPLAY LIKE 'E'.
    ENDIF.

  ENDMETHOD.

ENDCLASS.

