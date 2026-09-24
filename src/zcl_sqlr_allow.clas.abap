" The allow-list: which tables each user may read with this tool.
"
" The guard (ZCL_SQLR_GUARD) says what a statement reads. This says whether the
" person running it may. Two classes rather than one because they fail for
" different reasons and a reader chasing one should not have to read the other.
"
" What this list is, and it is worth being blunt about it: **a grant**. Spec
" 036 section 4.5 -- ordinary table authorisations are not checked, so an entry
" here gives the user it names access to that table, whatever their role says
" elsewhere. An entry for the user * gives it to everybody. Adding a line is a
" decision taken on somebody else's behalf, which is why changing it needs its
" own activity on Z_SQLR_RUN and every change records who made it. A table
" with one sensitive column does not belong here; a view that omits the
" column does.
"
" Per user since 24 September 2026, so that several people can work with
" separately verified lists. Until then there was one list for everybody;
" its entries moved to the user *, which is what they had meant all along.
"
" The matching half is pure and takes its entries as a parameter, so the rules
" can be tested without a database and without a client.
"
" The maintenance half at the bottom does not check authorisations. That is
" ZCL_SQLR_AUTH's job and the screen's: this class refuses nonsense, not
" people.
CLASS zcl_sqlr_allow DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.

    " The user an entry names to mean everybody.
    CONSTANTS c_everybody TYPE xubname VALUE '*'.

    TYPES: BEGIN OF ty_entry,
             uname  TYPE xubname,
             entry  TYPE c LENGTH 30,
             active TYPE abap_bool,
           END OF ty_entry.
    TYPES tt_entry TYPE STANDARD TABLE OF ty_entry WITH EMPTY KEY.

    " One row of the maintenance grid: the grant plus its provenance.
    "
    " changed_at is text, not a timestamp, and deliberately: a grid over a
    " local type has no data element to format a packed timestamp with, so
    " it prints the raw number -- 20.260.923.114.941,0000000.
    TYPES: BEGIN OF ty_row,
             uname      TYPE xubname,
             tabname    TYPE tabname,
             reason     TYPE c LENGTH 120,
             changed_by TYPE xubname,
             changed_at TYPE c LENGTH 19,
           END OF ty_row.
    TYPES tt_row TYPE STANDARD TABLE OF ty_row WITH EMPTY KEY.

    TYPES: BEGIN OF ty_verdict,
             ok      TYPE abap_bool,
             refused TYPE string,
             diag    TYPE zcl_sqlr_guard=>ty_diag,
           END OF ty_verdict.

    "! What a save did, so the screen can say so in numbers.
    TYPES: BEGIN OF ty_saved,
             ok      TYPE abap_bool,
             diag    TYPE zcl_sqlr_guard=>ty_diag,
             added   TYPE i,
             removed TYPE i,
             changed TYPE i,
           END OF ty_saved.

    "! Every source the guard found, against the list of the user running it.
    "! @parameter it_entries | The list. Read from the table when not supplied,
    "!                         which is what the running tool does; supplied
    "!                         by the tests, which have no table.
    "! @parameter iv_user    | Whose list. The person running the statement;
    "!                         in a background job, the job step's user.
    CLASS-METHODS check
      IMPORTING it_sources        TYPE zcl_sqlr_guard=>tt_source
                it_entries        TYPE tt_entry OPTIONAL
                iv_user           TYPE xubname DEFAULT sy-uname
      RETURNING VALUE(rs_verdict) TYPE ty_verdict.

    "! One name against one list, for one user. Pure, and the whole of the
    "! matching rule.
    CLASS-METHODS matches
      IMPORTING iv_name           TYPE string
                it_entries        TYPE tt_entry
                iv_user           TYPE xubname DEFAULT sy-uname
      RETURNING VALUE(rv_allowed) TYPE abap_bool.

    "! The active entries that apply to this session's user, read once.
    CLASS-METHODS load
      RETURNING VALUE(rt_entries) TYPE tt_entry.

    "! Forgets what load( ) cached. For a session that has just maintained the
    "! list and must not keep answering from the version before the change.
    CLASS-METHODS forget.

    "! Every active grant, every user, for the maintenance grid.
    CLASS-METHODS rows
      RETURNING VALUE(rt_rows) TYPE tt_row.

    "! Is this a name or pattern the list can hold?
    CLASS-METHODS valid_entry
      IMPORTING iv_entry          TYPE string
      RETURNING VALUE(rs_verdict) TYPE ty_verdict.

    "! Is this somebody a grant can be for? A user of this client, or *.
    CLASS-METHODS valid_user
      IMPORTING iv_user           TYPE string
      RETURNING VALUE(rs_verdict) TYPE ty_verdict.

    "! Makes the active list what the grid says it is.
    "!
    "! The whole list goes in, not one change at a time, because that is what
    "! a grid hands back. Every row is checked before anything is written; one
    "! bad row and nothing is saved, so a list is never left half-changed.
    "! A row that has gone is deactivated, not deleted: the list keeps who
    "! removed what and when.
    "! Not called REPLACE, though that is what it does: a method of that name
    "! shadows the built-in string function inside this class, and replace(
    "! val = ... ) then refuses to compile.
    CLASS-METHODS store
      IMPORTING it_rows         TYPE tt_row
      RETURNING VALUE(rs_saved) TYPE ty_saved.

  PRIVATE SECTION.

    CLASS-DATA gt_cache  TYPE tt_entry.
    CLASS-DATA gv_loaded TYPE abap_bool.

    CLASS-METHODS refuse
      IMPORTING iv_code           TYPE string
                iv_what           TYPE string
                iv_why            TYPE string
                iv_fix            TYPE string
      RETURNING VALUE(rs_verdict) TYPE ty_verdict.

ENDCLASS.


CLASS zcl_sqlr_allow IMPLEMENTATION.

  METHOD matches.

    DATA(lv_name) = to_upper( condense( iv_name ) ).
    IF lv_name IS INITIAL.
      RETURN.
    ENDIF.

    LOOP AT it_entries INTO DATA(ls_entry) WHERE active = abap_true.

      " An entry is somebody's: this user's, or everybody's. Another user's
      " grant is exactly what per-user lists exist to keep apart.
      IF ls_entry-uname <> c_everybody AND ls_entry-uname <> iv_user.
        CONTINUE.
      ENDIF.

      DATA(lv_pattern) = to_upper( condense( CONV string( ls_entry-entry ) ) ).
      IF lv_pattern IS INITIAL.
        CONTINUE.
      ENDIF.

      " A pattern is a name with a star in it. Everything else is compared
      " whole -- an entry for MARA allows MARA and nothing that merely starts
      " with it, because MARA_BACKUP is a different table with different rows.
      IF lv_pattern CA '*'.
        IF lv_name CP lv_pattern.
          rv_allowed = abap_true.
          RETURN.
        ENDIF.
      ELSEIF lv_name = lv_pattern.
        rv_allowed = abap_true.
        RETURN.
      ENDIF.

    ENDLOOP.

  ENDMETHOD.


  METHOD check.

    DATA(lt_entries) = it_entries.
    IF lt_entries IS INITIAL AND it_entries IS NOT SUPPLIED.
      lt_entries = load( ).
    ENDIF.

    LOOP AT it_sources INTO DATA(ls_source).

      IF matches( iv_name    = ls_source-name
                  it_entries = lt_entries
                  iv_user    = iv_user ) = abap_true.
        CONTINUE.
      ENDIF.

      " Named, and named for whom, so the person can ask for exactly that.
      " The refusal says where to ask, because the next thing they want is to
      " get it added, and a message that stops at "not allowed" sends them to
      " the wrong person first.
      "
      " The space belongs at the front of the second literal, not the end of
      " the first: a quoted ABAP literal loses its trailing blanks, and the
      " two sentences ran together in the first version of this message.
      rs_verdict-refused   = ls_source-name.
      rs_verdict-diag-code = 'NOT_ALLOWED'.
      rs_verdict-diag-what = 'Checking the statement.'.
      rs_verdict-diag-why  = |{ ls_source-name } is not on the list of tables { iv_user } may read.|.
      rs_verdict-diag-fix  = 'Press Admin on this screen to see the lists and who last changed them.' &&
                             ' Adding to them needs Z_SQLR_RUN activity 02; without that, ask somebody who holds it.'.
      RETURN.

    ENDLOOP.

    rs_verdict-ok = abap_true.

  ENDMETHOD.


  METHOD load.

    " Once per session. The list changes rarely and is read for every
    " statement; a maintenance session calls forget( ) so it does not answer
    " from the version before its own change. Only the entries that can apply
    " to this session's user are read -- everybody's, and theirs.
    IF gv_loaded = abap_true.
      rt_entries = gt_cache.
      RETURN.
    ENDIF.

    SELECT uname, tabname AS entry, active
      FROM zsqlr_grant
      WHERE active = @abap_true
        AND ( uname = @sy-uname OR uname = @c_everybody )
      INTO CORRESPONDING FIELDS OF TABLE @gt_cache.

    gv_loaded = abap_true.
    rt_entries = gt_cache.

  ENDMETHOD.


  METHOD forget.
    CLEAR: gt_cache, gv_loaded.
  ENDMETHOD.


  METHOD rows.

    SELECT uname, tabname, reason, changed_by, changed_at
      FROM zsqlr_grant
      WHERE active = @abap_true
      ORDER BY uname, tabname
      INTO TABLE @DATA(lt_raw).

    " ISO, less the T. The letter is there so a machine can parse the
    " timestamp back; nobody reading a column of them needs it.
    LOOP AT lt_raw INTO DATA(ls_raw).
      APPEND VALUE #( uname      = ls_raw-uname
                      tabname    = ls_raw-tabname
                      reason     = ls_raw-reason
                      changed_by = ls_raw-changed_by
                      changed_at = replace( val  = |{ ls_raw-changed_at TIMESTAMP = ISO }|
                                            sub  = `T`
                                            with = ` ` ) ) TO rt_rows.
    ENDLOOP.

  ENDMETHOD.


  METHOD valid_entry.

    DATA(lv_entry) = to_upper( condense( iv_entry ) ).

    IF lv_entry IS INITIAL.
      rs_verdict = refuse(
        iv_code = 'NO_ENTRY'
        iv_what = 'Adding a table to a list.'
        iv_why  = 'A row has a user but no table.'
        iv_fix  = 'Type the table name, or a pattern such as ZSALES_*, or remove the row.' ).
      RETURN.
    ENDIF.

    IF strlen( lv_entry ) > 30.
      rs_verdict = refuse(
        iv_code = 'ENTRY_TOO_LONG'
        iv_what = 'Adding a table to a list.'
        iv_why  = |"{ lv_entry }" is longer than the 30 characters a table name can be.|
        iv_fix  = 'Check the name. If you meant a group of tables, a pattern is shorter.' ).
      RETURN.
    ENDIF.

    " A star on its own would hand over the database, and somebody will try
    " it the first afternoon. It is not a typo to be corrected quietly.
    IF lv_entry = '*'.
      rs_verdict = refuse(
        iv_code = 'ENTRY_TOO_WIDE'
        iv_what = 'Adding a table to a list.'
        iv_why  = 'A single star as the table would allow every table in the database, including the ones holding passwords and payroll.'
        iv_fix  = 'Name the tables, or a prefix that ends somewhere -- ZSALES_* rather than *.' ).
      RETURN.
    ENDIF.

    " Letters, digits, underscore, slash for namespaces, star for patterns.
    DATA(lv_rest) = lv_entry.
    REPLACE ALL OCCURRENCES OF PCRE `[A-Z0-9_/\*]` IN lv_rest WITH ``.
    IF lv_rest IS NOT INITIAL.
      rs_verdict = refuse(
        iv_code = 'ENTRY_NOT_ALLOWED'
        iv_what = 'Adding a table to a list.'
        iv_why  = |"{ lv_entry }" has characters a table name cannot have: { lv_rest }|
        iv_fix  = 'Letters, digits, underscore, slash and star only.' ).
      RETURN.
    ENDIF.

    rs_verdict-ok = abap_true.

  ENDMETHOD.


  METHOD valid_user.

    DATA(lv_user) = to_upper( condense( iv_user ) ).

    IF lv_user IS INITIAL.
      rs_verdict = refuse(
        iv_code = 'NO_USER'
        iv_what = 'Adding a table to a list.'
        iv_why  = 'A row has a table but no user.'
        iv_fix  = 'Type the user it is for, or * for everybody, or remove the row.' ).
      RETURN.
    ENDIF.

    IF lv_user = c_everybody.
      rs_verdict-ok = abap_true.
      RETURN.
    ENDIF.

    " Users are per client, like the list. A grant for a user that does not
    " exist here is a typo that would otherwise sit unnoticed until the day
    " somebody is created with that name.
    SELECT SINGLE bname FROM usr02 WHERE bname = @lv_user INTO @DATA(lv_found).
    IF sy-subrc <> 0.
      rs_verdict = refuse(
        iv_code = 'NO_SUCH_USER'
        iv_what = |Adding a table to the list of { lv_user }.|
        iv_why  = |There is no user { lv_user } in client { sy-mandt }.|
        iv_fix  = 'Check the name -- F4 on the user column lists them -- or use * for everybody.' ).
      RETURN.
    ENDIF.

    rs_verdict-ok = abap_true.

  ENDMETHOD.


  METHOD store.

    TYPES: BEGIN OF ty_key,
             uname   TYPE xubname,
             tabname TYPE tabname,
             reason  TYPE c LENGTH 120,
           END OF ty_key.
    DATA lt_want TYPE SORTED TABLE OF ty_key WITH UNIQUE KEY uname tabname.
    DATA lv_user TYPE xubname.
    DATA lv_tab  TYPE tabname.

    " --- every row checked before anything is written ------------------

    LOOP AT it_rows INTO DATA(ls_row).

      lv_user = to_upper( condense( CONV string( ls_row-uname ) ) ).
      lv_tab  = to_upper( condense( CONV string( ls_row-tabname ) ) ).

      " A row the grid appended and nobody filled in is not a mistake to
      " refuse, it is nothing.
      IF lv_user IS INITIAL AND lv_tab IS INITIAL.
        CONTINUE.
      ENDIF.

      DATA(ls_user) = valid_user( CONV string( lv_user ) ).
      IF ls_user-ok = abap_false.
        rs_saved-diag = ls_user-diag.
        RETURN.
      ENDIF.

      DATA(ls_entry) = valid_entry( CONV string( lv_tab ) ).
      IF ls_entry-ok = abap_false.
        rs_saved-diag = ls_entry-diag.
        RETURN.
      ENDIF.

      INSERT VALUE #( uname = lv_user tabname = lv_tab reason = ls_row-reason )
        INTO TABLE lt_want.
      IF sy-subrc <> 0.
        rs_saved-diag = refuse(
          iv_code = 'DUPLICATE'
          iv_what = 'Saving the lists.'
          iv_why  = |{ lv_tab } is on the list of { lv_user } twice.|
          iv_fix  = 'Remove one of the two rows.' )-diag.
        RETURN.
      ENDIF.

    ENDLOOP.

    " --- what is there now ---------------------------------------------

    SELECT uname, tabname, reason
      FROM zsqlr_grant
      WHERE active = @abap_true
      INTO TABLE @DATA(lt_have).
    SORT lt_have BY uname tabname.

    GET TIME STAMP FIELD DATA(lv_now).

    " What changed, in words, for SLG1. Built alongside the writes so the
    " log says exactly what was done, not what was asked for.
    DATA lt_lines TYPE string_table.

    " --- added, brought back, or with a new reason ---------------------

    LOOP AT lt_want INTO DATA(ls_want).

      READ TABLE lt_have INTO DATA(ls_have)
        WITH KEY uname = ls_want-uname tabname = ls_want-tabname BINARY SEARCH.

      IF sy-subrc = 0.
        IF ls_have-reason = ls_want-reason.
          CONTINUE.
        ENDIF.
        UPDATE zsqlr_grant
          SET reason     = @ls_want-reason,
              changed_by = @sy-uname,
              changed_at = @lv_now
          WHERE uname = @ls_want-uname AND tabname = @ls_want-tabname.
        rs_saved-changed = rs_saved-changed + 1.
        APPEND |Reason changed: { ls_want-uname } / { ls_want-tabname }, | &&
               |"{ condense( CONV string( ls_have-reason ) ) }" -> | &&
               |"{ condense( CONV string( ls_want-reason ) ) }"| TO lt_lines.
        CONTINUE.
      ENDIF.

      " MODIFY, not INSERT: a grant removed earlier is still a row, inactive,
      " and comes back rather than failing on a key that is there.
      MODIFY zsqlr_grant FROM @( VALUE zsqlr_grant( mandt      = sy-mandt
                                                     uname      = ls_want-uname
                                                     tabname    = ls_want-tabname
                                                     active     = abap_true
                                                     reason     = ls_want-reason
                                                     changed_by = sy-uname
                                                     changed_at = lv_now ) ).
      rs_saved-added = rs_saved-added + 1.
      APPEND |Added: { ls_want-uname } may read { ls_want-tabname }| &&
             COND string( WHEN ls_want-reason IS INITIAL THEN ``
                          ELSE | -- { condense( CONV string( ls_want-reason ) ) }| ) TO lt_lines.

    ENDLOOP.

    " --- gone from the grid: deactivated, kept ---------------------------

    LOOP AT lt_have INTO ls_have.
      READ TABLE lt_want TRANSPORTING NO FIELDS
        WITH TABLE KEY uname = ls_have-uname tabname = ls_have-tabname.
      IF sy-subrc = 0.
        CONTINUE.
      ENDIF.
      UPDATE zsqlr_grant
        SET active     = @abap_false,
            changed_by = @sy-uname,
            changed_at = @lv_now
        WHERE uname = @ls_have-uname AND tabname = @ls_have-tabname.
      rs_saved-removed = rs_saved-removed + 1.
      APPEND |Removed: { ls_have-uname } may no longer read { ls_have-tabname }| TO lt_lines.
    ENDLOOP.

    " Nothing changed, nothing to record. A save of an untouched grid is
    " not an event.
    IF lt_lines IS INITIAL.
      rs_saved-ok = abap_true.
      RETURN.
    ENDIF.

    " --- the audit entry, in the same unit of work -----------------------
    "
    " Required for audit (24 Sept 2026): every change to these lists goes to
    " SLG1, object ZSQLR, subobject GRANT. The entry is written before the
    " commit and committed with the change, so the two cannot part company:
    " when the log cannot be written, the change is rolled back and refused.
    DATA(lv_headline) = |{ sy-uname } changed the table lists: | &&
                        |{ rs_saved-added } added, { rs_saved-removed } removed, | &&
                        |{ rs_saved-changed } with a new reason|.

    IF zcl_sqlr_log=>grants_changed( iv_headline = lv_headline
                                     it_lines    = lt_lines ) = abap_false.
      ROLLBACK WORK.
      CLEAR: rs_saved-added, rs_saved-removed, rs_saved-changed.
      rs_saved-diag = refuse(
        iv_code = 'AUDIT_LOG'
        iv_what = 'Saving the table lists.'
        iv_why  = 'The change could not be recorded in the application log (SLG1, object ZSQLR, subobject GRANT), and a change that is not recorded is not made.'
        iv_fix  = 'Nothing was saved. Check in SLG0 that ZSQLR has a subobject GRANT, then save again.' )-diag.
      RETURN.
    ENDIF.

    COMMIT WORK AND WAIT.

    " The cache would otherwise keep answering from the list as it was
    " before this change, for the rest of the session that made it.
    forget( ).

    rs_saved-ok = abap_true.

  ENDMETHOD.


  METHOD refuse.
    rs_verdict-ok        = abap_false.
    rs_verdict-diag-code = iv_code.
    rs_verdict-diag-what = iv_what.
    rs_verdict-diag-why  = iv_why.
    rs_verdict-diag-fix  = iv_fix.
  ENDMETHOD.

ENDCLASS.

