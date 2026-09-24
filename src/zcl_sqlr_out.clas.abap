" Where the answer goes when it is not a grid.
"
" Four destinations, two formats, and one rule holding them together: the
" screen decides nothing about how a file is made, so a background job
" producing the same extract produces the same bytes. ZSQLR_RUN calls this
" and so does a scheduled variant of it; neither has its own copy.
"
" CSV is streamed. The rows are written package by package through
" ZCL_SQLR_EXEC=>stream and never gathered, so a server file is bounded by
" the disk rather than by the work process -- which is the size promise in
" spec 036 §6, and the only place it is actually kept.
"
" XLSX cannot be. SAP builds the workbook from a table that has to be
" complete, and Excel itself stops at 1,048,576 rows, so the format brings
" its own ceiling and this class says so rather than failing at it.
CLASS zcl_sqlr_out DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.

    CONSTANTS: c_csv  TYPE string VALUE 'CSV',
               c_xlsx TYPE string VALUE 'XLSX'.

    CONSTANTS: c_grid   TYPE string VALUE 'GRID',
               c_local  TYPE string VALUE 'LOCAL',
               c_server TYPE string VALUE 'SERVER',
               c_mail   TYPE string VALUE 'MAIL'.

    " Excel's own limit, less the header row. Beyond it a workbook is not
    " a large workbook, it is a corrupt one.
    CONSTANTS c_xlsx_max TYPE i VALUE 1048575.

    TYPES: BEGIN OF ty_outcome,
             ok        TYPE abap_bool,
             rows      TYPE i,
             bytes     TYPE i,
             truncated TYPE abap_bool,
             " One sentence for the status bar or the job log.
             note      TYPE string,
             diag      TYPE zcl_sqlr_guard=>ty_diag,
           END OF ty_outcome.

    "! Runs the statement and puts the result where it was asked to go.
    "! The statement arrives already checked by the guard, the allow-list
    "! and the client rewrite: this class does not repeat that work and
    "! must never be called with anything that has skipped it.
    CLASS-METHODS deliver
      IMPORTING iv_sql            TYPE string
                iv_target         TYPE string
                iv_format         TYPE string DEFAULT c_csv
                iv_separator      TYPE c DEFAULT ';'
                iv_path           TYPE string OPTIONAL
                it_recipient      TYPE string_table OPTIONAL
                iv_subject        TYPE string OPTIONAL
                iv_name           TYPE string OPTIONAL
                iv_max_rows       TYPE i DEFAULT 0
                iv_attach_sql     TYPE abap_bool DEFAULT abap_true
                iv_statement      TYPE string OPTIONAL
                iv_every_client   TYPE abap_bool DEFAULT abap_false
      RETURNING VALUE(rs_outcome) TYPE ty_outcome.

    "! The path with the extension the format calls for. A file name
    "! picked while the format was CSV and then switched to Excel would
    "! otherwise be a workbook called .csv, which Excel then refuses.
    "! .csv and .xlsx are corrected, no extension gets one, and anything
    "! else is left alone as a deliberate choice.
    CLASS-METHODS with_extension
      IMPORTING iv_path        TYPE string
                iv_format      TYPE string
      RETURNING VALUE(rv_path) TYPE string.

    "! Is there a front end to hand a file to? False in a background job,
    "! which is the case that has to be refused rather than dumped on.
    CLASS-METHODS front_end
      RETURNING VALUE(rv_present) TYPE abap_bool.

    "! A column out of ADBC has no data element, so the ALV has no header
    "! text for it and draws an empty box. The name the query gave it is
    "! the only name there is. Used by the grid and by the workbook, so
    "! both show the same headings.
    CLASS-METHODS label_columns
      IMPORTING io_columns TYPE REF TO cl_salv_columns_table.

    CLASS-METHODS file_name
      IMPORTING iv_name        TYPE string OPTIONAL
                iv_format      TYPE string DEFAULT c_csv
      RETURNING VALUE(rv_name) TYPE string.

  PRIVATE SECTION.

    CLASS-METHODS refuse
      IMPORTING iv_code           TYPE string
                iv_what           TYPE string
                iv_why            TYPE string
                iv_fix            TYPE string
      RETURNING VALUE(rs_outcome) TYPE ty_outcome.

    CLASS-METHODS as_csv
      IMPORTING iv_sql            TYPE string
                iv_separator      TYPE c
                iv_path           TYPE string
                iv_max_rows       TYPE i
      EXPORTING ev_content        TYPE xstring
      RETURNING VALUE(rs_outcome) TYPE ty_outcome.

    CLASS-METHODS as_xlsx
      IMPORTING iv_sql            TYPE string
                iv_max_rows       TYPE i
      EXPORTING ev_content        TYPE xstring
      RETURNING VALUE(rs_outcome) TYPE ty_outcome.

    CLASS-METHODS to_server
      IMPORTING iv_content        TYPE xstring
                iv_path           TYPE string
      RETURNING VALUE(rs_outcome) TYPE ty_outcome.

    CLASS-METHODS to_local
      IMPORTING iv_content        TYPE xstring
                iv_path           TYPE string
      RETURNING VALUE(rs_outcome) TYPE ty_outcome.

    CLASS-METHODS to_mail
      IMPORTING iv_content        TYPE xstring
                iv_file           TYPE string
                iv_subject        TYPE string
                iv_sql            TYPE string
                iv_rows           TYPE i
                it_recipient      TYPE string_table
                iv_attach_sql     TYPE abap_bool
                iv_statement      TYPE string
                iv_every_client   TYPE abap_bool
      RETURNING VALUE(rs_outcome) TYPE ty_outcome.

    CLASS-METHODS as_solix
      IMPORTING iv_content       TYPE xstring
      RETURNING VALUE(rt_solix)  TYPE solix_tab.

ENDCLASS.


CLASS zcl_sqlr_out IMPLEMENTATION.

  METHOD front_end.
    " Non-zero means no front end: a job step, an RFC, a background work
    " process. The name reads backwards and is SAP's, not ours.
    rv_present = xsdbool( sy-batch = abap_false AND cl_gui_alv_grid=>offline( ) = 0 ).
  ENDMETHOD.


  METHOD with_extension.

    DATA(lv_want) = COND string( WHEN iv_format = c_xlsx THEN `.xlsx` ELSE `.csv` ).

    IF matches( val = iv_path pcre = `.*\.(csv|xlsx)` case = abap_false ).
      rv_path = replace( val = iv_path pcre = `\.[^.]*$` with = lv_want ).
    ELSEIF matches( val = iv_path pcre = `.*\.[^.\\/]*` ).
      " An extension of some other kind on the last segment of the path.
      rv_path = iv_path.
    ELSE.
      rv_path = |{ iv_path }{ lv_want }|.
    ENDIF.

  ENDMETHOD.


  METHOD file_name.

    DATA(lv_stem) = COND string( WHEN iv_name IS INITIAL THEN `SQLR` ELSE iv_name ).

    GET TIME STAMP FIELD DATA(lv_now).
    DATA(lv_stamp) = |{ lv_now TIMESTAMP = ISO }|.
    " 2026-09-23T14:15:07 -> 20260923_141507, which sorts and survives
    " every file system this file might land on.
    REPLACE ALL OCCURRENCES OF `-` IN lv_stamp WITH ``.
    REPLACE ALL OCCURRENCES OF `:` IN lv_stamp WITH ``.
    REPLACE ALL OCCURRENCES OF `T` IN lv_stamp WITH `_`.

    DATA(lv_ext) = COND string( WHEN iv_format = c_xlsx THEN `xlsx` ELSE `csv` ).

    rv_name = |{ lv_stem }_{ lv_stamp }.{ lv_ext }|.

  ENDMETHOD.


  METHOD label_columns.

    LOOP AT io_columns->get( ) INTO DATA(ls_column).
      DATA(lv_name)   = CONV string( ls_column-columnname ).
      DATA(lo_column) = CAST cl_salv_column( ls_column-r_column ).
      lo_column->set_short_text( CONV scrtext_s( lv_name ) ).
      lo_column->set_medium_text( CONV scrtext_m( lv_name ) ).
      lo_column->set_long_text( CONV scrtext_l( lv_name ) ).
    ENDLOOP.

  ENDMETHOD.


  METHOD deliver.

    DATA lv_content TYPE xstring.

    " --- who may send it there -----------------------------------------

    " Checked here as well as on the screen, and deliberately twice. The
    " screen is one caller; this method is the boundary, and a boundary
    " that trusts its callers is not one. Spec 037 section 8.
    "
    " Where a result goes is the right that matters most in this tool:
    " reading a table inside SAP and mailing it out of SAP are not the
    " same act, and only this field tells them apart.
    DATA(ls_channel) = zcl_sqlr_auth=>may_send_to( zcl_sqlr_auth=>channel_of( iv_target ) ).
    IF ls_channel-ok = abap_false.
      rs_outcome-diag = ls_channel-diag.
      RETURN.
    ENDIF.

    " The same for reading every client. The statement arrives already
    " built, so this class cannot tell a rewritten one from one that was
    " not; what it can do is refuse to deliver an answer it was told spans
    " every client to somebody who may not have it.
    IF iv_every_client = abap_true.
      DATA(ls_client) = zcl_sqlr_auth=>may_read_every_client( ).
      IF ls_client-ok = abap_false.
        rs_outcome-diag = ls_client-diag.
        RETURN.
      ENDIF.
    ENDIF.

    " --- what cannot be done, said before anything is read -------------

    IF iv_target = c_local AND front_end( ) = abap_false.
      rs_outcome = refuse(
        iv_code = 'NO_FRONT_END'
        iv_what = 'Writing the result to a file on your own machine.'
        iv_why  = 'This is running without a front end -- a background job has no PC to write to.'
        iv_fix  = 'Schedule it to the application server or to e-mail instead. Both work unattended.' ).
      RETURN.
    ENDIF.

    " In a browser a path on "your own machine" means nothing: SAP GUI for
    " HTML hands the file to the browser as a download and the browser
    " decides where it lands, using only the name. So an empty field is not
    " a refusal there; the name is made up the same way the mail
    " attachment's is. On a desktop the path does decide where the file
    " goes, and an empty one is still refused.
    DATA(lv_path) = iv_path.
    IF iv_target = c_local AND lv_path IS INITIAL
       AND cl_gui_object=>www_active IS NOT INITIAL.
      lv_path = file_name( iv_name = iv_name iv_format = iv_format ).
    ENDIF.

    IF iv_target = c_local OR iv_target = c_server.
      IF lv_path IS INITIAL.
        rs_outcome = refuse(
          iv_code = 'NO_PATH'
          iv_what = 'Writing the result to a file.'
          iv_why  = 'No file name was given.'
          iv_fix  = |Fill the file field. F4 on it opens a save dialog for your own machine; for the server, AL11 shows the directories this system knows.| ).
        RETURN.
      ENDIF.
    ENDIF.

    IF iv_target = c_server AND lv_path CS `..`.
      rs_outcome = refuse(
        iv_code = 'PATH_TRAVERSAL'
        iv_what = |Writing to { lv_path } on the application server.|
        iv_why  = 'The path steps back up the directory tree with "..", which this tool does not write through.'
        iv_fix  = 'Give the directory in full, as AL11 lists it.' ).
      RETURN.
    ENDIF.

    IF iv_target = c_mail.
      IF it_recipient IS INITIAL.
        rs_outcome = refuse(
          iv_code = 'NO_RECIPIENT'
          iv_what = 'Sending the result by e-mail.'
          iv_why  = 'Nobody was named to send it to.'
          iv_fix  = 'Fill in at least one address.' ).
        RETURN.
      ENDIF.
      LOOP AT it_recipient INTO DATA(lv_address).
        IF lv_address NS `@`.
          rs_outcome = refuse(
            iv_code = 'BAD_ADDRESS'
            iv_what = 'Sending the result by e-mail.'
            iv_why  = |"{ lv_address }" is not an e-mail address.|
            iv_fix  = 'Correct it. This tool sends to internet addresses, not to SAP user names.' ).
          RETURN.
        ENDIF.
      ENDLOOP.
    ENDIF.

    IF iv_target = c_local OR iv_target = c_server.
      lv_path = with_extension( iv_path = lv_path iv_format = iv_format ).
    ENDIF.

    " --- reading it ----------------------------------------------------

    DATA(lv_cap) = iv_max_rows.

    IF iv_format = c_xlsx.
      IF lv_cap = 0 OR lv_cap > c_xlsx_max.
        lv_cap = c_xlsx_max.
      ENDIF.
      rs_outcome = as_xlsx( EXPORTING iv_sql      = iv_sql
                                      iv_max_rows = lv_cap
                            IMPORTING ev_content  = lv_content ).
    ELSE.
      " Straight to disk when it is going to disk: the rows are written as
      " they arrive and the file never exists in memory at all.
      DATA(lv_stream_to) = COND string( WHEN iv_target = c_server THEN lv_path ).
      rs_outcome = as_csv( EXPORTING iv_sql       = iv_sql
                                     iv_separator = iv_separator
                                     iv_path      = lv_stream_to
                                     iv_max_rows  = lv_cap
                           IMPORTING ev_content   = lv_content ).
    ENDIF.

    IF rs_outcome-ok = abap_false.
      RETURN.
    ENDIF.

    IF rs_outcome-rows = 0.
      rs_outcome-note = 'The statement ran and returned no rows. Nothing was sent.'.
      RETURN.
    ENDIF.

    " --- putting it somewhere ------------------------------------------

    DATA(lv_rows)      = rs_outcome-rows.
    DATA(lv_truncated) = rs_outcome-truncated.
    DATA(lv_bytes)     = rs_outcome-bytes.

    CASE iv_target.

      WHEN c_server.
        IF iv_format = c_xlsx.
          rs_outcome = to_server( iv_content = lv_content iv_path = lv_path ).
        ELSE.
          " CSV went there as it was read. Nothing left to write.
          rs_outcome-ok = abap_true.
          rs_outcome-note = |{ lv_rows } row(s) written to { lv_path }.|.
        ENDIF.

      WHEN c_local.
        rs_outcome = to_local( iv_content = lv_content iv_path = lv_path ).

      WHEN c_mail.
        rs_outcome = to_mail( iv_content   = lv_content
                              iv_file      = file_name( iv_name   = iv_name
                                                        iv_format = iv_format )
                              iv_subject   = iv_subject
                              iv_sql       = iv_sql
                              iv_rows      = lv_rows
                              it_recipient = it_recipient
                              iv_attach_sql = iv_attach_sql
                              iv_every_client = iv_every_client
                              " As typed, not as rewritten: what a person
                              " wrote is what a person can read. A caller
                              " that has no typed version sends what ran.
                              iv_statement = COND #( WHEN iv_statement IS NOT INITIAL
                                                     THEN iv_statement
                                                     ELSE iv_sql ) ).

      WHEN OTHERS.
        rs_outcome = refuse(
          iv_code = 'NO_TARGET'
          iv_what = 'Sending the result somewhere.'
          iv_why  = |"{ iv_target }" is not a destination this tool knows.|
          iv_fix  = 'Choose one of the output options on the screen.' ).

    ENDCASE.

    rs_outcome-rows      = lv_rows.
    rs_outcome-bytes     = lv_bytes.
    rs_outcome-truncated = lv_truncated.

    IF rs_outcome-ok = abap_true AND lv_truncated = abap_true.
      rs_outcome-note = |{ rs_outcome-note } This is the first { lv_rows } rows, not all of them -- raise or clear the row cap.|.
    ENDIF.

  ENDMETHOD.


  METHOD as_csv.

    CLEAR ev_content.

    DATA(lo_sink) = NEW zcl_sqlr_sink_csv( iv_separator = iv_separator
                                           iv_path      = iv_path ).

    DATA(ls_run) = zcl_sqlr_exec=>stream( iv_sql      = iv_sql
                                          io_sink     = lo_sink
                                          iv_max_rows = iv_max_rows ).

    rs_outcome-rows      = ls_run-rows.
    rs_outcome-truncated = ls_run-truncated.
    rs_outcome-bytes     = lo_sink->bytes( ).
    rs_outcome-ok        = ls_run-ok.
    rs_outcome-diag      = ls_run-diag.

    ev_content = lo_sink->content( ).

  ENDMETHOD.


  METHOD as_xlsx.

    CLEAR ev_content.

    FIELD-SYMBOLS <lt_rows> TYPE STANDARD TABLE.

    DATA(ls_run) = zcl_sqlr_exec=>run( iv_sql      = iv_sql
                                       iv_max_rows = iv_max_rows ).
    IF ls_run-ok = abap_false.
      rs_outcome-diag = ls_run-diag.
      RETURN.
    ENDIF.

    rs_outcome-rows      = ls_run-rows.
    rs_outcome-truncated = ls_run-truncated.

    IF ls_run-rows = 0.
      rs_outcome-ok = abap_true.
      RETURN.
    ENDIF.

    ASSIGN ls_run-data->* TO <lt_rows>.
    IF <lt_rows> IS NOT ASSIGNED.
      RETURN.
    ENDIF.

    DATA lo_alv TYPE REF TO cl_salv_table.
    TRY.
        " Built in memory and never displayed. The same class the grid
        " uses, so the workbook and the screen carry the same headings.
        cl_salv_table=>factory( IMPORTING r_salv_table = lo_alv
                                CHANGING  t_table      = <lt_rows> ).
        label_columns( lo_alv->get_columns( ) ).

        ev_content = lo_alv->to_xml( xml_type = if_salv_bs_xml=>c_type_xlsx ).

        rs_outcome-bytes = xstrlen( ev_content ).
        rs_outcome-ok    = abap_true.

      CATCH cx_root INTO DATA(lx).
        rs_outcome = refuse(
          iv_code = 'XLSX'
          iv_what = 'Building the workbook.'
          iv_why  = lx->get_text( )
          iv_fix  = 'Try CSV: it is built here rather than by the spreadsheet transformation, and has no row limit.' ).
    ENDTRY.

  ENDMETHOD.


  METHOD to_server.

    DATA lv_msg TYPE string.

    OPEN DATASET iv_path FOR OUTPUT IN BINARY MODE MESSAGE lv_msg.
    IF sy-subrc <> 0.
      rs_outcome = refuse(
        iv_code = 'SERVER_FILE_OPEN'
        iv_what = |Writing { iv_path } on the application server.|
        iv_why  = |The server refused it: { lv_msg }|
        iv_fix  = 'Check the directory exists and that you hold S_DATASET for it. AL11 lists the directories this system knows.' ).
      RETURN.
    ENDIF.

    " LENGTH will not take an expression, only a data object.
    DATA(lv_length) = xstrlen( iv_content ).
    TRANSFER iv_content TO iv_path LENGTH lv_length.
    CLOSE DATASET iv_path.

    rs_outcome-ok    = abap_true.
    rs_outcome-bytes = xstrlen( iv_content ).
    rs_outcome-note  = |Written to { iv_path } on the application server.|.

  ENDMETHOD.


  METHOD to_local.

    DATA(lt_solix) = as_solix( iv_content ).
    DATA(lv_size)  = xstrlen( iv_content ).
    DATA(lv_path)  = iv_path.

    cl_gui_frontend_services=>gui_download(
      EXPORTING bin_filesize = lv_size
                filename     = lv_path
                filetype     = 'BIN'
      CHANGING  data_tab     = lt_solix
      EXCEPTIONS OTHERS      = 1 ).

    IF sy-subrc <> 0.
      rs_outcome = refuse(
        iv_code = 'LOCAL_FILE'
        iv_what = |Saving { iv_path } on your own machine.|
        iv_why  = 'The front end would not write it.'
        iv_fix  = 'Check the folder exists and that the file is not open in another programme, then try again.' ).
      RETURN.
    ENDIF.

    rs_outcome-ok    = abap_true.
    rs_outcome-bytes = lv_size.
    rs_outcome-note  = |Saved to { iv_path }.|.

  ENDMETHOD.


  METHOD to_mail.

    DATA lt_body TYPE soli_tab.

    TRY.
        DATA(lv_subject) = COND string( WHEN iv_subject IS INITIAL
                                        THEN |SQL reporting: { iv_file }|
                                        ELSE iv_subject ).

        " The statement travels as an attachment, and only when asked for.
        " It used to sit in the body unconditionally, which made the choice
        " not to send it impossible: a mail to somebody outside the team is
        " not always a mail that should carry the query. Whoever receives
        " it can still tell what they are looking at -- the body says who
        " ran it and where -- and SLG1 keeps the statement either way.
        DATA(lv_sql_file) = replace( val = iv_file pcre = `\.[^.]*$` with = `.sql` ).

        APPEND VALUE #( line = |{ iv_rows } row(s), attached as { iv_file }.| ) TO lt_body.
        IF iv_attach_sql = abap_true.
          APPEND VALUE #( line = |The statement that produced them is attached as { lv_sql_file }.| ) TO lt_body.
        ENDIF.
        APPEND VALUE #( ) TO lt_body.
        APPEND VALUE #( line = COND #( WHEN iv_every_client = abap_true
                                       THEN |Run by { sy-uname } across every client of { sy-sysid }.|
                                       ELSE |Run by { sy-uname } in client { sy-mandt } of { sy-sysid }.| ) ) TO lt_body.

        DATA(lo_document) = cl_document_bcs=>create_document(
          i_type    = 'RAW'
          i_subject = CONV so_obj_des( lv_subject )
          i_text    = lt_body ).

        lo_document->add_attachment(
          i_attachment_type     = 'BIN'
          i_attachment_subject  = CONV sood-objdes( iv_file )
          i_attachment_size     = CONV sood-objlen( xstrlen( iv_content ) )
          i_att_content_hex     = as_solix( iv_content )
          i_attachment_filename = iv_file ).

        IF iv_attach_sql = abap_true.
          " UTF-8, with Windows line ends so it opens as lines in anything a
          " recipient is likely to double-click it in.
          DATA(lv_sql_text) = replace( val  = iv_statement
                                       sub  = cl_abap_char_utilities=>newline
                                       with = cl_abap_char_utilities=>cr_lf
                                       occ  = 0 ).
          DATA(lv_sql_x) = cl_abap_conv_codepage=>create_out( )->convert( lv_sql_text ).

          lo_document->add_attachment(
            i_attachment_type     = 'BIN'
            i_attachment_subject  = CONV sood-objdes( lv_sql_file )
            i_attachment_size     = CONV sood-objlen( xstrlen( lv_sql_x ) )
            i_att_content_hex     = as_solix( lv_sql_x )
            i_attachment_filename = lv_sql_file ).
        ENDIF.

        DATA(lo_send) = cl_bcs=>create_persistent( ).
        lo_send->set_document( lo_document ).

        LOOP AT it_recipient INTO DATA(lv_address).
          lo_send->add_recipient(
            cl_cam_address_bcs=>create_internet_address(
              CONV adr6-smtp_addr( lv_address ) ) ).
        ENDLOOP.

        lo_send->set_send_immediately( abap_true ).
        DATA(lv_sent) = lo_send->send( i_with_error_screen = abap_false ).

        " The send request is a database object. Without the commit it is
        " rolled back at the end of the dialog step and nothing ever goes.
        COMMIT WORK.

        IF lv_sent = abap_false.
          rs_outcome = refuse(
            iv_code = 'MAIL_QUEUED'
            iv_what = 'Sending the result by e-mail.'
            iv_why  = 'SAP took the message but did not hand it to a recipient.'
            iv_fix  = 'Look at it in SOST. Usually the send job (RSCONN01) is not scheduled, or the address is not one this system may send to.' ).
          RETURN.
        ENDIF.

        rs_outcome-ok    = abap_true.
        rs_outcome-bytes = xstrlen( iv_content ).
        rs_outcome-note  = |Sent to { lines( it_recipient ) } recipient(s) as { iv_file }. SOST shows what happened to it.|.

      CATCH cx_root INTO DATA(lx).
        rs_outcome = refuse(
          iv_code = 'MAIL'
          iv_what = 'Sending the result by e-mail.'
          iv_why  = lx->get_text( )
          iv_fix  = 'Check the addresses. If they are right, SOST and SCOT show whether this system can send mail at all.' ).
    ENDTRY.

  ENDMETHOD.


  METHOD as_solix.

    CALL FUNCTION 'SCMS_XSTRING_TO_BINARY'
      EXPORTING
        buffer     = iv_content
      TABLES
        binary_tab = rt_solix.

  ENDMETHOD.


  METHOD refuse.
    rs_outcome-ok        = abap_false.
    rs_outcome-diag-code = iv_code.
    rs_outcome-diag-what = iv_what.
    rs_outcome-diag-why  = iv_why.
    rs_outcome-diag-fix  = iv_fix.
  ENDMETHOD.

ENDCLASS.

