" Who may do what. Every AUTHORITY-CHECK in this tool is in this class.
"
" One object, Z_SQLR_RUN, with three fields:
"
"   ACTVT     16 run a query   03 see the table list   02 change it
"   ZSQLROUT  A grid   L file here   S file on the server   M e-mail
"   ZSQLRCLI  C this client   X every client
"
" Maintaining the table list is an activity on this object rather than an
" object of its own. That is a deliberate simplification of what spec 037
" section 8 first described: the list is maintained from inside the same
" transaction, by people who already have that transaction, and a second
" object to express "and may also edit the list" is a second thing for
" somebody to forget to assign.
"
" It is not a small right, though, and the gap between 16 and 02 is the
" point. The list is a **grant**: ordinary table authorisations are not
" checked (FSD section 4.5), so adding a line to it gives every query
" author access to that table. Running queries is an everyday permission.
" Changing what may be queried is not, and separating them is the whole
" reason this object has an ACTVT field at all.
"
" Every refusal comes back in three parts, like everything else here, and
" the third part names what to ask for -- a person told only "not
" authorised" asks the wrong colleague first.
CLASS zcl_sqlr_auth DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.

    TYPES ty_channel TYPE c LENGTH 1.

    CONSTANTS: c_run     TYPE activ_auth VALUE '16',
               c_display TYPE activ_auth VALUE '03',
               c_change  TYPE activ_auth VALUE '02'.

    CONSTANTS: c_grid   TYPE ty_channel VALUE 'A',
               c_local  TYPE ty_channel VALUE 'L',
               c_server TYPE ty_channel VALUE 'S',
               c_mail   TYPE ty_channel VALUE 'M'.

    CONSTANTS: c_this_client  TYPE ty_channel VALUE 'C',
               c_every_client TYPE ty_channel VALUE 'X'.

    TYPES: BEGIN OF ty_verdict,
             ok   TYPE abap_bool,
             diag TYPE zcl_sqlr_guard=>ty_diag,
           END OF ty_verdict.

    "! Has this user any business on this screen at all?
    CLASS-METHODS anything
      RETURNING VALUE(rv_ok) TYPE abap_bool.

    CLASS-METHODS may_run
      RETURNING VALUE(rs_verdict) TYPE ty_verdict.

    CLASS-METHODS may_see_tables
      RETURNING VALUE(rs_verdict) TYPE ty_verdict.

    CLASS-METHODS may_change_tables
      RETURNING VALUE(rs_verdict) TYPE ty_verdict.

    "! @parameter iv_channel | One of c_grid, c_local, c_server, c_mail.
    CLASS-METHODS may_send_to
      IMPORTING iv_channel        TYPE ty_channel
      RETURNING VALUE(rs_verdict) TYPE ty_verdict.

    CLASS-METHODS may_read_every_client
      RETURNING VALUE(rs_verdict) TYPE ty_verdict.

    " Reading the log is the same right as seeing the table list: both are
    " read-only views of the tool's own records rather than of anybody's
    " data. The message differs because the question does.
    CLASS-METHODS may_read_log
      RETURNING VALUE(rs_verdict) TYPE ty_verdict.

    "! The destination names ZCL_SQLR_OUT uses, as the one-letter values
    "! the authorisation field holds. Two vocabularies because one is read
    "! by people in PFCG and the other by people in code, and a field that
    "! is ten characters wide in a role is a field nobody fills correctly.
    CLASS-METHODS channel_of
      IMPORTING iv_target         TYPE string
      RETURNING VALUE(rv_channel) TYPE ty_channel.

  PRIVATE SECTION.

    CLASS-METHODS allowed
      IMPORTING iv_actvt     TYPE activ_auth
      RETURNING VALUE(rv_ok) TYPE abap_bool.

    CLASS-METHODS refuse
      IMPORTING iv_what           TYPE string
                iv_why            TYPE string
                iv_fix            TYPE string
      RETURNING VALUE(rs_verdict) TYPE ty_verdict.

ENDCLASS.


CLASS zcl_sqlr_auth IMPLEMENTATION.

  METHOD allowed.

    " Every field of the object has to be named, even the ones this check
    " does not care about. Leave one out and the check fails with subrc 8
    " rather than being ignored -- which is the right way round, and is why
    " DUMMY is spelled out here instead of omitted.
    AUTHORITY-CHECK OBJECT 'Z_SQLR_RUN'
      ID 'ACTVT'    FIELD iv_actvt
      ID 'ZSQLROUT' DUMMY
      ID 'ZSQLRCLI' DUMMY.

    rv_ok = xsdbool( sy-subrc = 0 ).

  ENDMETHOD.


  METHOD anything.
    rv_ok = xsdbool(    allowed( c_run )     = abap_true
                     OR allowed( c_display ) = abap_true
                     OR allowed( c_change )  = abap_true ).
  ENDMETHOD.


  METHOD may_run.

    IF allowed( c_run ) = abap_true.
      rs_verdict-ok = abap_true.
      RETURN.
    ENDIF.

    rs_verdict = refuse(
      iv_what = 'Running a query.'
      iv_why  = |{ sy-uname } is not authorised to run queries in this system.|
      iv_fix  = 'Ask for authorisation object Z_SQLR_RUN with activity 16 (Execute).' ).

  ENDMETHOD.


  METHOD may_see_tables.

    IF allowed( c_display ) = abap_true.
      rs_verdict-ok = abap_true.
      RETURN.
    ENDIF.

    rs_verdict = refuse(
      iv_what = 'Showing the list of tables this tool may read.'
      iv_why  = |{ sy-uname } is not authorised to see the list.|
      iv_fix  = 'Ask for authorisation object Z_SQLR_RUN with activity 03 (Display).' ).

  ENDMETHOD.


  METHOD may_change_tables.

    IF allowed( c_change ) = abap_true.
      rs_verdict-ok = abap_true.
      RETURN.
    ENDIF.

    " The space goes at the front of each continuation, not the end of the
    " line before it: a quoted ABAP literal loses its trailing blanks.
    rs_verdict = refuse(
      iv_what = 'Changing the list of tables this tool may read.'
      iv_why  = |{ sy-uname } may look at the list but not change it.|
      iv_fix  = 'Ask for authorisation object Z_SQLR_RUN with activity 02 (Change).' &&
                ' It is a larger right than it looks: an entry on this list gives every' &&
                ' query author access to that table.' ).

  ENDMETHOD.


  METHOD may_read_log.

    IF allowed( c_display ) = abap_true.
      rs_verdict-ok = abap_true.
      RETURN.
    ENDIF.

    rs_verdict = refuse(
      iv_what = 'Reading the record of what has been run.'
      iv_why  = |{ sy-uname } is not authorised to read the log.|
      iv_fix  = 'Ask for authorisation object Z_SQLR_RUN with activity 03 (Display).' ).

  ENDMETHOD.


  METHOD may_send_to.

    AUTHORITY-CHECK OBJECT 'Z_SQLR_RUN'
      ID 'ACTVT'    FIELD c_run
      ID 'ZSQLROUT' FIELD iv_channel
      ID 'ZSQLRCLI' DUMMY.

    IF sy-subrc = 0.
      rs_verdict-ok = abap_true.
      RETURN.
    ENDIF.

    DATA(lv_where) = SWITCH string( iv_channel
      WHEN c_grid   THEN `to a grid on the screen`
      WHEN c_local  THEN `to a file on your own machine`
      WHEN c_server THEN `to a file on the application server`
      WHEN c_mail   THEN `out of this system by e-mail`
      ELSE               |through channel "{ iv_channel }"| ).

    rs_verdict = refuse(
      iv_what = 'Sending the result somewhere.'
      iv_why  = |{ sy-uname } may run queries, but not send a result { lv_where }.|
      iv_fix  = |Ask for Z_SQLR_RUN with ZSQLROUT = { iv_channel }, or choose a destination you hold.| ).

  ENDMETHOD.


  METHOD may_read_every_client.

    AUTHORITY-CHECK OBJECT 'Z_SQLR_RUN'
      ID 'ACTVT'    FIELD c_run
      ID 'ZSQLROUT' DUMMY
      ID 'ZSQLRCLI' FIELD c_every_client.

    IF sy-subrc = 0.
      rs_verdict-ok = abap_true.
      RETURN.
    ENDIF.

    rs_verdict = refuse(
      iv_what = 'Reading every client rather than this one.'
      iv_why  = |{ sy-uname } may read this client only.|
      iv_fix  = 'Ask for Z_SQLR_RUN with ZSQLRCLI = X. Untick the box to run here.' ).

  ENDMETHOD.


  METHOD channel_of.
    rv_channel = SWITCH #( iv_target
      WHEN zcl_sqlr_out=>c_local  THEN c_local
      WHEN zcl_sqlr_out=>c_server THEN c_server
      WHEN zcl_sqlr_out=>c_mail   THEN c_mail
      ELSE                             c_grid ).
  ENDMETHOD.


  METHOD refuse.
    rs_verdict-ok        = abap_false.
    rs_verdict-diag-code = 'NOT_AUTHORISED'.
    rs_verdict-diag-what = iv_what.
    rs_verdict-diag-why  = iv_why.
    rs_verdict-diag-fix  = iv_fix.
  ENDMETHOD.

ENDCLASS.
