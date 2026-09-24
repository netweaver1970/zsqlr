REPORT zsqlr_run.

*&---------------------------------------------------------------------*
*& The screen: write a statement, check it, run it.
*&
*& A selection screen with a docking container rather than a dialog
*& program with a dynpro, and that is a deliberate trade. The editor
*& needs a custom control, a custom control needs a container, and a
*& docking container attaches to the screen that is already there --
*& including a selection screen. What it buys is that the whole program
*& is source code: no screen painter, no flow logic, nothing that has to
*& be maintained in a place a diff cannot show.
*&
*& What it costs is everything in this program to do with the editor
*& control, and it is worth knowing before changing any of it:
*&
*&   * get_text does not read the editor. It queues a request, and the
*&     table it was given stays as it was until CL_GUI_CFW=>FLUSH runs.
*&     Every read here flushes.
*&   * the container does not survive a trip out to list processing and
*&     back, so it is rebuilt after every run from the draft.
*&
*& The statement lives in the editor, not in a parameter, which is the
*& point: a PARAMETERS field stops at 255 characters and real reporting
*& SQL does not.
*&
*& Running it is F8, the standard Execute, so it goes through
*& START-OF-SELECTION like every other report in the system. That is not
*& decoration: it is also what makes this program schedulable. A job has
*& no editor, so a scheduled variant carries the query's NAME and the
*& statement is read from the store -- which is why a query name has to
*& be something a variant can hold, and why the name rule is as strict as
*& it is.
*&
*& The table list is maintained from here too, behind its own activity on
*& Z_SQLR_RUN. It has no transaction of its own on purpose: it is edited
*& by people who already have this one, and a second transaction is a
*& second thing for somebody to forget to assign.
*&---------------------------------------------------------------------*

TYPE-POOLS vrm.

TABLES sscrfields.

DATA gv_address TYPE adr6-smtp_addr.

" A named type for the format listbox. Declared inline as TYPE c LENGTH 4
" it cannot also carry USER-COMMAND -- the two additions are refused
" together -- and the user command is what takes the separator off the
" screen the moment Excel is chosen.
TYPES ty_format TYPE c LENGTH 4.

*--- The screen above the editor ----------------------------------------
" Kept to one line a block wherever it can be, because every line up here
" is a line of SQL the editor below cannot show. A field inside BEGIN OF
" LINE loses its selection text, so each one carries a COMMENT instead,
" worded in INITIALIZATION. No frames, either: SAP GUI for HTML draws
" each framed block with a title bar and padding several lines tall, and
" three frames round three one-line groups was mostly frame. Nothing on a
" line may run past column 75, and nothing may touch the next thing on
" its line: a line
" that overruns or overlaps is not cut off, selection screen 1000 simply
" fails to generate, and the activation message does not say which line.
" An integer parameter takes more columns than its digits suggest -- that
" is what ran the row cap into the label after it the first time.

SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 2(17) c_qname FOR FIELD p_query.
PARAMETERS p_query TYPE c LENGTH 30.
SELECTION-SCREEN END OF LINE.

" The description on a line of its own, and shown at its full sixty. Beside
" the name it could only ever be a dozen characters wide, which is not
" enough to say what a query answers.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 2(17) c_qdesc FOR FIELD p_descr.
PARAMETERS p_descr TYPE c LENGTH 60 VISIBLE LENGTH 60 LOWER CASE.
SELECTION-SCREEN END OF LINE.

*--- Where the answer goes ---------------------------------------------
" The four destinations on one line, and below them only what the chosen
" one uses. The rest are taken off the screen, not greyed: a greyed-out
" recipient list is a question that does not have to be answered, and it
" is also three lines of SQL nobody can see.

SELECTION-SCREEN BEGIN OF LINE.
PARAMETERS p_alv RADIOBUTTON GROUP tgt DEFAULT 'X' USER-COMMAND tgt.
SELECTION-SCREEN COMMENT 3(15) c_grid FOR FIELD p_alv.
SELECTION-SCREEN POSITION 20.
PARAMETERS p_local RADIOBUTTON GROUP tgt.
SELECTION-SCREEN COMMENT 22(17) c_local FOR FIELD p_local.
SELECTION-SCREEN POSITION 41.
PARAMETERS p_srv RADIOBUTTON GROUP tgt.
SELECTION-SCREEN COMMENT 43(17) c_srv FOR FIELD p_srv.
SELECTION-SCREEN POSITION 62.
PARAMETERS p_mail RADIOBUTTON GROUP tgt.
SELECTION-SCREEN COMMENT 64(10) c_mail FOR FIELD p_mail.
SELECTION-SCREEN END OF LINE.

" A user command on the format, so choosing Excel takes the separator away
" at once rather than on the next unrelated round trip. The attach tickbox
" rides on the same line: it only shows for e-mail, and a line of its own
" would be one more line of SQL out of sight. It says whether the
" statement goes with the mail -- ticked by default, because a result
" nobody can trace back to its query is a result nobody can check, and
" untickable for the mail that should not carry the query, which the old
" unconditional copy in the body made impossible to send.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 2(11) c_fmt FOR FIELD p_fmt.
PARAMETERS p_fmt TYPE ty_format AS LISTBOX VISIBLE LENGTH 14 DEFAULT 'CSV' USER-COMMAND fmt.
SELECTION-SCREEN COMMENT 31(10) c_sep FOR FIELD p_sep.
PARAMETERS p_sep TYPE c LENGTH 1 DEFAULT ';'.
SELECTION-SCREEN POSITION 48.
PARAMETERS p_sqlatt AS CHECKBOX DEFAULT 'X'.
SELECTION-SCREEN COMMENT 50(25) c_sqlatt FOR FIELD p_sqlatt.
SELECTION-SCREEN END OF LINE.

PARAMETERS p_file TYPE c LENGTH 128 LOWER CASE.

SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 2(11) c_to FOR FIELD s_rcpt.
SELECT-OPTIONS s_rcpt FOR gv_address NO INTERVALS LOWER CASE VISIBLE LENGTH 40.
SELECTION-SCREEN END OF LINE.

" The subject on its own line too, at its full sixty, for the same reason
" as the description. LOWER CASE, or a subject typed as "Monthly stock"
" arrives as "MONTHLY STOCK" -- a selection-screen field uppercases unless
" told not to.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 2(11) c_subj FOR FIELD p_subj.
PARAMETERS p_subj TYPE c LENGTH 60 VISIBLE LENGTH 60 LOWER CASE.
SELECTION-SCREEN END OF LINE.

*--- Settings ----------------------------------------------------------
" Max rows: an ALV keeps every row in memory on the application server,
" so this is the cap that matters in the dialog case. A streamed CSV needs
" none -- leave it at zero and the file is as long as the answer is
" (spec 036 section 6).
"
" Highlight as: only SAP GUI for Windows draws highlighting, so the field
" is taken off the screen everywhere else. Defaulted to ABAP after the
" experiment of 23 September 2026 -- SQL as a source type is unproven.
"
" Every client: the right to is ZSQLRCLI = X on Z_SQLR_RUN, and it is
" checked even though the reading itself is not built yet, so that
" somebody who may not is told that rather than told it is missing.
SELECTION-SCREEN BEGIN OF LINE.
SELECTION-SCREEN COMMENT 2(16) c_max FOR FIELD p_max.
PARAMETERS p_max TYPE i DEFAULT 500.
SELECTION-SCREEN COMMENT 35(12) c_hl FOR FIELD p_hl.
PARAMETERS p_hl TYPE c LENGTH 10 DEFAULT 'ABAP'.
SELECTION-SCREEN POSITION 60.
PARAMETERS p_cross AS CHECKBOX.
SELECTION-SCREEN COMMENT 62(13) c_cross FOR FIELD p_cross.
SELECTION-SCREEN END OF LINE.

SELECTION-SCREEN FUNCTION KEY 1.
SELECTION-SCREEN FUNCTION KEY 2.
SELECTION-SCREEN FUNCTION KEY 3.
SELECTION-SCREEN FUNCTION KEY 4.
SELECTION-SCREEN FUNCTION KEY 5.


CLASS lcl_app DEFINITION CREATE PRIVATE.

  PUBLIC SECTION.
    CLASS-METHODS build_screen.
    CLASS-METHODS arrange_screen.
    CLASS-METHODS apply_highlighting.
    CLASS-METHODS offer_formats.
    CLASS-METHODS command IMPORTING iv_ucomm TYPE sy-ucomm.
    CLASS-METHODS remember.
    CLASS-METHODS execute.
    CLASS-METHODS pick_query.
    CLASS-METHODS pick_file.
    CLASS-METHODS refused_at_the_door.

    "! The grant grid's user command. Public only because the ALV function
    "! module calls back by FORM name, and a FORM is outside this class.
    CLASS-METHODS grid_command
      IMPORTING iv_ucomm    TYPE sy-ucomm
      CHANGING  cs_selfield TYPE slis_selfield.

  PRIVATE SECTION.

    " What a stored line holds. ZSQLR_QTEXT-LINE is CHAR 255 and so is
    " RSWSOURCET, so this is the width the statement has to be folded to
    " before anything keeps it. It is not a limit on what can be written.
    CONSTANTS c_line_length TYPE i VALUE 255.

    " How wide a line the program reads out of an editor, which is a
    " different question from how wide it stores one, and has to be larger.
    "
    " A saved query lost the tails of two lines on 23 September 2026. The
    " likeliest place is the read: the text used to be fetched into a CHAR
    " 255 table, and a longer line was cut at the transfer. It is not the
    " control cutting as it is pasted -- that was the first reading, and it
    " was wrong: CL_GUI_SOURCEEDIT's MAX_NUMBER_CHARS is passed straight on
    " as its WordWrapPosition, which wraps a line and cuts nothing. So the
    " read is now this wide, and tidy( ) folds what comes back.
    CONSTANTS c_edit_width TYPE i VALUE 1024.

    TYPES ty_wide_line TYPE c LENGTH 1024.
    TYPES ty_wide      TYPE STANDARD TABLE OF ty_wide_line WITH EMPTY KEY.

    CLASS-DATA go_dock TYPE REF TO cl_gui_docking_container.

    " Two controls, one job, and no common ancestor: CL_GUI_SOURCEEDIT does
    " not inherit from CL_GUI_TEXTEDIT and their text methods are named
    " differently. So both references are kept and every place that touches
    " the text says which one it means.
    CLASS-DATA go_source TYPE REF TO cl_gui_sourceedit.
    CLASS-DATA go_plain  TYPE REF TO cl_gui_textedit.

    " The statement as it stood when the screen was last left. Read here
    " because START-OF-SELECTION runs after the screen has gone, and the
    " editor with it.
    CLASS-DATA gt_last TYPE rswsourcet.

    " What this run will be logged as. Filled as the run goes; written
    " once, at the end, by execute( ).
    CLASS-DATA gs_run TYPE zcl_sqlr_log=>ty_run.

    " Set when a run has just been out to list processing and back.
    CLASS-DATA gv_came_back TYPE abap_bool.

    " Said once a session, not once a screen. The message is an
    " explanation, not a warning, and repeating it every round trip would
    " crowd out the messages that are.
    CLASS-DATA gv_told_no_editor TYPE abap_bool.

    " The editor's share of the window, in per cent. A share rather than a
    " height in pixels, because the window is not always the same size and
    " the fields above the editor are. Tuned for a window about 680 pixels
    " high; a taller one leaves a band above the editor, never an overlap.
    "
    " A different share means a new container: a docking container has
    " SET_EXTENSION in pixels but no SET_RATIO.
    "
    " The browser shares are of the area under the toolbar -- that is what
    " SAP GUI for HTML measures against whenever a container is rebuilt.
    " The very first container of the session it measures against the
    " whole page instead, some 90 pixels taller, so that one is scaled
    " down by c_first_build_scale or it would cover the fields.
    CONSTANTS: c_share_web_grid    TYPE i VALUE 71,
               c_share_web_file    TYPE i VALUE 60,
               c_share_web_mail    TYPE i VALUE 55,
               c_first_build_scale TYPE i VALUE 85.

    " SAP GUI for Windows and Java lay lines out far tighter than a browser
    " does, so the desktop front ends get their own set.
    CONSTANTS: c_share_gui_grid TYPE i VALUE 80,
               c_share_gui_file TYPE i VALUE 73,
               c_share_gui_mail TYPE i VALUE 69.

    CLASS-DATA gv_dock_built TYPE abap_bool.
    CLASS-DATA gv_share TYPE i.

    CLASS-METHODS statement
      RETURNING VALUE(rv_sql) TYPE string.

    "! Puts text into whichever editor this front end gave us.
    CLASS-METHODS set_statement
      IMPORTING it_text TYPE rswsourcet.

    "! Reads the editor as lines rather than as one string: the store keeps
    "! lines, and a round trip through a single string would lose where the
    "! author broke them.
    CLASS-METHODS statement_lines
      RETURNING VALUE(rt_text) TYPE rswsourcet.

    "! The statement as the editor holds it, at whatever width that is.
    "! Nothing is trimmed or folded here: this is the last point at which
    "! the text is still exactly what was typed.
    CLASS-METHODS raw_lines
      RETURNING VALUE(rt_raw) TYPE string_table.

    "! The same text, made fit to keep: trailing blank lines dropped, and
    "! any line longer than a stored line folded at a space rather than
    "! cut. Folding is safe where cutting is not -- SQL does not care
    "! where the line breaks fall, and it does care about the characters.
    CLASS-METHODS tidy
      IMPORTING it_raw         TYPE string_table
      RETURNING VALUE(rt_text) TYPE rswsourcet.

    CLASS-METHODS have_editor
      RETURNING VALUE(rv_yes) TYPE abap_bool.

    CLASS-METHODS check.
    CLASS-METHODS save_query.
    CLASS-METHODS open_query.
    CLASS-METHODS delete_query.

    "! The allow-list, from inside this transaction rather than from one of
    "! its own. Seeing it needs activity 03; changing it needs 02.
    "! Key 5 covers both read-only views of the tool's own records: the
    "! table list and the log. They share a button because they share a
    "! right -- activity 03 -- and because a selection screen has only
    "! five function keys and Check, Save, Open and Delete have the rest.
    CLASS-METHODS admin.
    CLASS-METHODS show_log.

    "! Who may read which tables, in one editable grid: a row per user and
    "! table, rows added and removed in place, one Save for the lot.
    "! Read-only without Z_SQLR_RUN activity 02.
    CLASS-METHODS maintain_tables.

    "! SLG1 on the grant changes rather than the runs.
    CLASS-METHODS show_grant_log.

    " The grid's rows, and whether this user may change them. Class data
    " because the grid function calls back into grid_command( ) with the
    " table it was given, not with a reference to it.
    " A grid row is a grant plus a Remove tickbox. The full-screen grid has
    " no add or delete row buttons in this release -- the unified toolbar
    " maps the grid's edit group to nothing, and a popup has no toolbar at
    " all -- so both are done in the data: empty lines at the bottom add,
    " the tickbox removes, and it works the same on every front end.
    TYPES BEGIN OF ty_grid_row.
    INCLUDE TYPE zcl_sqlr_allow=>ty_row.
    TYPES remove TYPE abap_bool.
    TYPES END OF ty_grid_row.
    TYPES tt_grid_row TYPE STANDARD TABLE OF ty_grid_row WITH EMPTY KEY.
    CONSTANTS c_blank_rows TYPE i VALUE 5.
    CLASS-DATA gt_grid      TYPE tt_grid_row.
    CLASS-DATA gv_grid_edit TYPE abap_bool.

    "! The stored grants, plus empty lines to type new ones into.
    CLASS-METHODS fill_grid.

    "! Whether the grid holds anything Save would change.
    CLASS-METHODS grid_changed RETURNING VALUE(rv_changed) TYPE abap_bool.

    "! Whether this user may run anything at all. Asked before every action
    "! that reads, and answered in one place.
    CLASS-METHODS cleared_to_run
      RETURNING VALUE(rv_ok) TYPE abap_bool.

    "! The run itself. execute( ) is the bracket around it that opens and
    "! closes the log entry, so that every way out of here is recorded --
    "! including the ones that are refusals.
    CLASS-METHODS run_now.

    "! What is to be run: the editor if there is one, the saved query if
    "! there is not. The second case is a background job.
    CLASS-METHODS statement_to_run
      RETURNING VALUE(rv_sql) TYPE string.

    CLASS-METHODS target
      RETURNING VALUE(rv_target) TYPE string.

    CLASS-METHODS recipients
      RETURNING VALUE(rt_address) TYPE string_table.

    "! Guard, allow-list and the client rewrite, in that order.
    "! Returns the statement as it should be sent, or explains itself.
    CLASS-METHODS approved
      IMPORTING iv_sql       TYPE string
      EXPORTING ev_sql       TYPE string
      RETURNING VALUE(rv_ok) TYPE abap_bool.

    CLASS-METHODS say
      IMPORTING is_diag TYPE zcl_sqlr_guard=>ty_diag.

    CLASS-METHODS show
      IMPORTING ir_data      TYPE REF TO data
                iv_rows      TYPE i
                iv_truncated TYPE abap_bool.

    "! Layouts belong to a query, not to this program. See the comment
    "! where it is used.
    CLASS-METHODS layout_handle
      RETURNING VALUE(rv_handle) TYPE salv_s_layout_key-handle.

ENDCLASS.


CLASS lcl_app IMPLEMENTATION.

  METHOD have_editor.
    rv_yes = xsdbool( go_source IS BOUND OR go_plain IS BOUND ).
  ENDMETHOD.


  METHOD raw_lines.

    DATA lv_stream TYPE string.

    IF go_source IS BOUND.

      " Read into a table as wide as the control, not as wide as a stored
      " line. GET_TEXT types its table generically, so this is allowed,
      " and reading into a 255 table would put the truncation back in --
      " at the transfer this time instead of at the paste.
      DATA lt_wide TYPE ty_wide.
      go_source->get_text( IMPORTING table = lt_wide EXCEPTIONS OTHERS = 1 ).
      IF sy-subrc <> 0.
        RETURN.
      ENDIF.

      " Queued, not done, until this runs. See the header of this program.
      cl_gui_cfw=>flush( EXCEPTIONS OTHERS = 1 ).

      LOOP AT lt_wide INTO DATA(lv_wide).
        APPEND CONV string( lv_wide ) TO rt_raw.
      ENDLOOP.
      RETURN.

    ENDIF.

    IF go_plain IS BOUND.

      " A stream has no line width at all, which is the whole reason for
      " preferring it wherever the control offers it.
      go_plain->get_textstream( IMPORTING text = lv_stream ).
      cl_gui_cfw=>flush( EXCEPTIONS OTHERS = 1 ).

      REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>cr_lf
        IN lv_stream WITH cl_abap_char_utilities=>newline.
      SPLIT lv_stream AT cl_abap_char_utilities=>newline INTO TABLE rt_raw.
      RETURN.

    ENDIF.

    " No control at all: a background job, where the statement is the one
    " held here or read by name.
    LOOP AT gt_last INTO DATA(lv_line).
      APPEND CONV string( lv_line ) TO rt_raw.
    ENDLOOP.

  ENDMETHOD.


  METHOD tidy.

    DATA(lt_raw) = it_raw.

    " The editor pads its last lines. Saving them would make every
    " reopened query a little longer than the one before it.
    "
    " Written the long way round because IS INITIAL wants a data object
    " and not an expression: condense( ... ) IS INITIAL does not compile.
    DATA lv_last TYPE string.
    WHILE lines( lt_raw ) > 0.
      lv_last = condense( lt_raw[ lines( lt_raw ) ] ).
      IF lv_last IS NOT INITIAL.
        EXIT.
      ENDIF.
      DELETE lt_raw INDEX lines( lt_raw ).
    ENDWHILE.

    DATA lv_cut  TYPE i.
    DATA lv_at   TYPE i.

    LOOP AT lt_raw INTO DATA(lv_line).

      WHILE strlen( lv_line ) > c_line_length.

        " Break at the last space that still fits. A break inside a token
        " would join two halves of an identifier across a line and the
        " statement would fail somewhere that reads nothing like here.
        lv_cut = c_line_length.
        lv_at  = c_line_length.
        WHILE lv_at > 0.
          IF substring( val = lv_line off = lv_at - 1 len = 1 ) = ` `.
            lv_cut = lv_at.
            EXIT.
          ENDIF.
          lv_at = lv_at - 1.
        ENDWHILE.

        " No space in the first 255 characters at all. One token that long
        " is not something a break can be kind about, so it is cut on the
        " boundary -- and still not lost, because the rest goes on the
        " next line.
        APPEND substring( val = lv_line len = lv_cut ) TO rt_text.
        lv_line = substring( val = lv_line off = lv_cut ).

      ENDWHILE.

      APPEND lv_line TO rt_text.

    ENDLOOP.

  ENDMETHOD.


  METHOD build_screen.

    " A background job has a selection screen too -- it simply never draws
    " it. Asking for a control there is how a scheduled report dumps.
    IF zcl_sqlr_out=>front_end( ) = abap_false.
      RETURN.
    ENDIF.

    " Coming back from a run. A docking container does not survive the
    " trip out to list processing and back: the reference is still bound,
    " the control behind it is gone, and the screen returns with an empty
    " editor -- which looks exactly like the tool having thrown the
    " statement away. It is rebuilt here from the draft, which is what
    " remember( ) stored on the way out.
    IF gv_came_back = abap_true.
      CLEAR gv_came_back.
      IF go_dock IS BOUND.
        go_dock->free( EXCEPTIONS OTHERS = 1 ).
      ENDIF.
      CLEAR: go_dock, go_source, go_plain.
    ENDIF.

    " The share this screen wants now. When it differs from the share the
    " container was built with, the container is built again. Nothing is
    " lost: remember( ) read the editor into the draft in this same round
    " trip, and the rebuilt editor is filled from it.
    DATA(lv_browser) = xsdbool( cl_gui_object=>www_active IS NOT INITIAL ).
    DATA(lv_share) = COND i(
      WHEN lv_browser = abap_true AND p_alv  = abap_true THEN c_share_web_grid
      WHEN lv_browser = abap_true AND p_mail = abap_true THEN c_share_web_mail
      WHEN lv_browser = abap_true                        THEN c_share_web_file
      WHEN p_alv  = abap_true                            THEN c_share_gui_grid
      WHEN p_mail = abap_true                            THEN c_share_gui_mail
      ELSE                                                    c_share_gui_file ).
    IF go_dock IS BOUND AND lv_share <> gv_share.
      go_dock->free( EXCEPTIONS OTHERS = 1 ).
      CLEAR: go_dock, go_source, go_plain.
    ENDIF.

    IF go_dock IS BOUND.
      RETURN.
    ENDIF.

    gv_share = lv_share.
    DATA(lv_ratio) = COND i(
      WHEN lv_browser = abap_true AND gv_dock_built = abap_false
      THEN lv_share * c_first_build_scale / 100
      ELSE lv_share ).
    gv_dock_built = abap_true.

    CREATE OBJECT go_dock
      EXPORTING
        repid     = sy-repid
        dynnr     = sy-dynnr
        side      = cl_gui_docking_container=>dock_at_bottom
        ratio     = lv_ratio
      EXCEPTIONS
        OTHERS    = 1.
    IF sy-subrc <> 0.
      MESSAGE 'The editor could not be placed on the screen.' TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

    " Whatever was on the screen last time, for this user. A half-written
    " statement is the thing most worth not losing and the thing least
    " worth naming and saving.
    DATA(lt_text) = COND rswsourcet( WHEN gt_last IS NOT INITIAL
                                     THEN gt_last
                                     ELSE zcl_sqlr_draft=>recall( ) ).
    IF lt_text IS INITIAL.
      lt_text = VALUE rswsourcet(
        ( |-- Write a SELECT. Check it before you run it.| )
        ( |-- Only tables on your table list can be read, and only this client.| )
        ( || )
        ( |SELECT matnr, mtart, matkl| )
        ( |  FROM mara| ) ).
    ENDIF.

    " Which editor, decided from what the front end IS, never from what
    " CREATE OBJECT answers. Creating a control does not talk to the front
    " end: it queues, and SY-SUBRC is 0 whatever is on the other end. A
    " refusal lands at the PBO flush instead, as CNDP 006 out of SAPLOLEA,
    " which nothing can catch.
    "
    " The source editor is for SAP GUI for Windows and nothing else. It
    " highlights, and Windows is the only front end that draws that: SAP GUI
    " for Java shows it without colours, and SAP GUI for HTML has only the
    " table call to feed it with, which it does not implement. Everywhere
    " else the plain editor is used, fed as a stream, which is the one
    " arrangement proven in a browser. Both sit in the same docking
    " container: it was never the container a browser refused (037, 5.1).
    "
    " Windows is the front end that is neither of the other two: Java
    " reports JavaBeans, and SAP GUI for HTML reports ITS (WWW_ACTIVE).
    " That is how CL_GUI_OBJECT=>CLASS_INIT sets them. Asked that way
    " round rather than as "ActiveX and not ITS" -- the same three answers
    " -- because abaplint's copy of CL_GUI_OBJECT has no ACTIVEX.
    "
    " MAX_NUMBER_CHARS is the control's wrap position and it is built for
    " 72 or 255 -- its edge marker is drawn at one or the other. Set to
    " 1024 on 23 September 2026, SAP GUI for Java drew the editor empty.
    DATA(lv_windows) = xsdbool( cl_gui_object=>javabean IS INITIAL
                                AND cl_gui_object=>www_active IS INITIAL ).
    IF lv_windows = abap_true.

      CREATE OBJECT go_source
        EXPORTING
          parent           = go_dock
          max_number_chars = c_line_length
        EXCEPTIONS
          OTHERS           = 1.

      IF sy-subrc = 0.
        go_source->set_source_type( CONV string( p_hl ) ).
        go_source->set_toolbar_mode( 1 ).
        go_source->set_statusbar_mode( 1 ).
        go_source->set_text( table = lt_text ).
        RETURN.
      ENDIF.

      CLEAR go_source.

    ENDIF.

    " Built exactly as proven in a browser on 24 September 2026, and used
    " the same way in SAP GUI for Java: fixed wrap position, wraps turned
    " into real line breaks, no status bar, toolbar mode left alone.
    CREATE OBJECT go_plain
      EXPORTING
        parent                     = go_dock
        wordwrap_mode              = cl_gui_textedit=>wordwrap_at_fixed_position
        wordwrap_position          = c_edit_width
        wordwrap_to_linebreak_mode = cl_gui_textedit=>true
      EXCEPTIONS
        OTHERS                     = 1.
    IF sy-subrc <> 0.
      CLEAR go_plain.
      MESSAGE 'No editor control could be created in this front end.' TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

    go_plain->set_statusbar_mode( cl_gui_textedit=>false ).

    set_statement( lt_text ).

    IF gv_told_no_editor = abap_false.
      gv_told_no_editor = abap_true.
      MESSAGE 'No highlighting in this front end. SAP GUI for Windows colours the keywords.' TYPE 'S'.
    ENDIF.

  ENDMETHOD.


  METHOD arrange_screen.

    " Only the fields the chosen destination actually uses, and the rest
    " taken off the screen rather than greyed -- every line up here is a
    " line of SQL the editor below cannot show.
    DATA(lv_file) = xsdbool( p_local = abap_true OR p_srv = abap_true ).

    LOOP AT SCREEN.

      " Format and separator: every destination but the grid.
      IF screen-name CS 'P_FMT' OR screen-name CS 'C_FMT'.
        screen-active = COND #( WHEN p_alv = abap_true THEN 0 ELSE 1 ).
      ENDIF.

      " The separator only means something for CSV.
      IF screen-name CS 'P_SEP' OR screen-name CS 'C_SEP'.
        screen-active = COND #( WHEN p_alv = abap_false AND p_fmt = zcl_sqlr_out=>c_csv
                                THEN 1 ELSE 0 ).
      ENDIF.

      IF screen-name CS 'P_FILE'.
        screen-active = COND #( WHEN lv_file = abap_true THEN 1 ELSE 0 ).
      ENDIF.

      IF screen-name CS 'S_RCPT' OR screen-name CS 'P_SUBJ'
         OR screen-name CS 'C_TO' OR screen-name CS 'C_SUBJ'
         OR screen-name CS 'P_SQLATT' OR screen-name CS 'C_SQLATT'.
        screen-active = COND #( WHEN p_mail = abap_true THEN 1 ELSE 0 ).
      ENDIF.

      " Highlighting is drawn by SAP GUI for Windows and nothing else.
      IF ( screen-name CS 'P_HL' OR screen-name CS 'C_HL' )
         AND go_source IS NOT BOUND.
        screen-active = 0.
      ENDIF.

      MODIFY SCREEN.

    ENDLOOP.

  ENDMETHOD.


  METHOD offer_formats.

    DATA lt_values TYPE vrm_values.

    lt_values = VALUE #(
      ( key = zcl_sqlr_out=>c_csv  text = 'CSV' )
      ( key = zcl_sqlr_out=>c_xlsx text = 'Excel (xlsx)' ) ).

    CALL FUNCTION 'VRM_SET_VALUES'
      EXPORTING
        id     = 'P_FMT'
        values = lt_values
      EXCEPTIONS
        OTHERS = 1.

  ENDMETHOD.


  METHOD apply_highlighting.

    " Setting the type alone does not repaint: the control sends it to the
    " front end when the text is set. So the text goes out and comes back,
    " which is how a language typed on the screen takes effect on the
    " statement already written there.
    IF go_source IS NOT BOUND OR p_hl IS INITIAL.
      RETURN.
    ENDIF.

    DATA lv_current TYPE string.
    go_source->get_source_type( IMPORTING source_type = lv_current ).
    IF lv_current = p_hl.
      RETURN.
    ENDIF.

    DATA lt_text TYPE rswsourcet.
    go_source->get_text( IMPORTING table = lt_text EXCEPTIONS OTHERS = 1 ).
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.
    cl_gui_cfw=>flush( EXCEPTIONS OTHERS = 1 ).

    go_source->set_source_type( CONV string( p_hl ) ).
    go_source->set_text( table = lt_text ).

  ENDMETHOD.


  METHOD statement.

    " Joined with line breaks, not spaces: a -- comment runs to the end of
    " its line, and flattening the text would swallow the line after it.
    CONCATENATE LINES OF raw_lines( ) INTO rv_sql
      SEPARATED BY cl_abap_char_utilities=>newline.

  ENDMETHOD.


  METHOD set_statement.

    IF go_source IS BOUND.
      go_source->set_text( table = it_text ).
    ELSEIF go_plain IS BOUND.
      " As a stream. The table call is not implemented by SAP GUI for HTML,
      " and it is the one call that killed the browser editor.
      DATA lv_stream TYPE string.
      CONCATENATE LINES OF it_text INTO lv_stream
        SEPARATED BY cl_abap_char_utilities=>cr_lf.
      go_plain->set_textstream( lv_stream ).
    ELSE.
      " No control: a background job, which reads the statement by name.
      gt_last = it_text.
    ENDIF.

  ENDMETHOD.


  METHOD statement_lines.

    rt_text = tidy( raw_lines( ) ).

  ENDMETHOD.


  METHOD remember.

    " Kept on every trip through the screen, not on leaving it: Back and
    " Cancel never reach this event, so a draft written only on the way out
    " would be lost to the one key most likely to be pressed.
    IF zcl_sqlr_out=>front_end( ) = abap_false.
      RETURN.
    ENDIF.

    DATA(lt_now) = statement_lines( ).

    " An empty read is not the same as an empty editor, and telling them
    " apart matters more than it sounds. When the control does not answer
    " -- which is what an unflushed automation queue looks like -- taking
    " the answer at face value throws the statement away, wipes the draft,
    " and leaves F8 with nothing to run.
    "
    " The first version of this guard only held while gt_last had
    " something in it, which left the first trip of a session unprotected
    " and, worse, still let an empty read reach zcl_sqlr_draft=>remember( )
    " and wipe the stored draft. Both are gone then, and the statement
    " really is lost. An empty read is now never written, full stop.
    "
    " The cost is that emptying the editor does not empty the draft. That
    " is the right way round: the draft is only ever read when there is
    " nothing else to show, and the next statement replaces it.
    IF lt_now IS INITIAL.
      RETURN.
    ENDIF.

    gt_last = lt_now.
    zcl_sqlr_draft=>remember( gt_last ).

  ENDMETHOD.


  METHOD save_query.

    IF cleared_to_run( ) = abap_false.
      RETURN.
    ENDIF.

    DATA(ls_saved) = zcl_sqlr_query=>save( iv_name  = CONV string( p_query )
                                           iv_descr = CONV string( p_descr )
                                           it_text  = statement_lines( ) ).
    IF ls_saved-ok = abap_false.
      say( ls_saved-diag ).
      RETURN.
    ENDIF.

    MESSAGE |Saved { p_query } as version { ls_saved-version }.| TYPE 'S'.

  ENDMETHOD.


  METHOD open_query.

    DATA ls_head TYPE zcl_sqlr_query=>ty_head.
    DATA lt_text TYPE rswsourcet.

    IF p_query IS INITIAL.
      say( VALUE #( code = 'NO_NAME'
                    what = 'Opening a saved query.'
                    why  = 'No query name is filled in.'
                    fix  = 'Type the name, or press F4 on Query name to pick from what is saved.' ) ).
      RETURN.
    ENDIF.

    IF zcl_sqlr_query=>load( EXPORTING iv_name = CONV string( p_query )
                             IMPORTING es_head = ls_head
                                       et_text = lt_text ) = abap_false.
      say( VALUE #( code = 'NOT_FOUND'
                    what = 'Opening the query.'
                    why  = |There is no saved query called { p_query }.|
                    fix  = 'Press F4 on the name to see what is saved.' ) ).
      RETURN.
    ENDIF.

    set_statement( lt_text ).
    gt_last = lt_text.
    p_descr = ls_head-descr.
    MESSAGE |{ p_query } version { ls_head-version }, last changed by { ls_head-changed_by }.| TYPE 'S'.

  ENDMETHOD.


  METHOD delete_query.

    IF cleared_to_run( ) = abap_false.
      RETURN.
    ENDIF.

    " Asked before doing, because the button is next to Save and the list is
    " shared -- this is somebody else's work as often as it is your own.
    DATA lv_answer TYPE c LENGTH 1.
    CALL FUNCTION 'POPUP_TO_CONFIRM'
      EXPORTING
        titlebar              = 'Retire this query'
        text_question         = |Retire { p_query }? It leaves the list; its versions are kept.|
        text_button_1         = 'Retire'
        text_button_2         = 'Keep'
        default_button        = '2'
        display_cancel_button = abap_false
      IMPORTING
        answer                = lv_answer
      EXCEPTIONS
        OTHERS                = 1.

    IF sy-subrc <> 0 OR lv_answer <> '1'.
      RETURN.
    ENDIF.

    DATA(ls_gone) = zcl_sqlr_query=>remove( CONV string( p_query ) ).
    IF ls_gone-ok = abap_false.
      say( ls_gone-diag ).
      RETURN.
    ENDIF.

    MESSAGE |{ p_query } retired. Saving the name again brings it back.| TYPE 'S'.

  ENDMETHOD.


  METHOD pick_query.

    " Two things had to be right here, and the first one hid the second.
    "
    " With value_org = 'S' and no column catalogue, F4IF_INT_TABLE_VALUE_REQUEST
    " builds one by asking the dictionary about the line type of value_tab.
    " A type declared inside a program has no dictionary entry to ask
    " about, so it raised PARAMETER_ERROR and the list never came up.
    " Handing it the real table fixed that and produced the second
    " problem: the whole table, every column, headed F0002, F0003, F0005
    " -- because a table built from abap.char() has no data elements and
    " therefore no field labels to draw -- and CHANGED_AT, a packed
    " timestamp, rendered as 20.260.923.120.758,0000000.
    "
    " Filling field_tab settles both. A supplied catalogue is used as
    " given, so the dictionary is never consulted, the line type may be
    " local again, and every heading is one written here. The timestamp
    " is formatted into text before it goes in, because the popup draws
    " what it is handed and nothing else.
    TYPES: BEGIN OF ty_pick,
             query_name TYPE c LENGTH 30,
             descr      TYPE c LENGTH 60,
             version    TYPE c LENGTH 5,
             changed_by TYPE c LENGTH 12,
             changed_at TYPE c LENGTH 19,
           END OF ty_pick.

    DATA lt_pick TYPE STANDARD TABLE OF ty_pick.

    SELECT query_name, descr, version, changed_by, changed_at
      FROM zsqlr_query
      WHERE active = @abap_true
      ORDER BY query_name
      INTO TABLE @DATA(lt_raw).

    IF lt_raw IS INITIAL.
      MESSAGE 'Nothing is saved yet.' TYPE 'S'.
      RETURN.
    ENDIF.

    LOOP AT lt_raw INTO DATA(ls_raw).
      APPEND VALUE ty_pick(
        query_name = ls_raw-query_name
        descr      = ls_raw-descr
        version    = |{ ls_raw-version }|
        changed_by = ls_raw-changed_by
        " 2026-09-23T11:49:41 -> 2026-09-23 11:49:41. The T is ISO 8601
        " being correct at the reader's expense.
        changed_at = replace( val  = |{ ls_raw-changed_at TIMESTAMP = ISO }|
                              sub  = `T`
                              with = ` ` ) ) TO lt_pick.
    ENDLOOP.

    " The column catalogue, and the one thing about it that is not
    " obvious: DFIES measures a field two different ways in the same row.
    " OFFSET and INTLEN are **bytes**; LENG and OUTPUTLEN are characters.
    " This system is Unicode, so a character is two bytes and the byte
    " figures are double the character ones.
    "
    " Getting that wrong does not fail, it slices. Every column came out
    " starting halfway through the one before it, and CHANGED_BY filled
    " with Chinese -- which is what a pair of ASCII letters looks like
    " when something reads it as one UTF-16 character.
    DATA lt_field TYPE STANDARD TABLE OF dfies.

    TYPES: BEGIN OF ty_col,
             name  TYPE fieldname,
             chars TYPE i,
             head  TYPE string,
           END OF ty_col.
    TYPES ty_cols TYPE STANDARD TABLE OF ty_col WITH EMPTY KEY.

    DATA(lt_col) = VALUE ty_cols(
      ( name = 'QUERY_NAME' chars = 30 head = `Query` )
      ( name = 'DESCR'      chars = 60 head = `Description` )
      ( name = 'VERSION'    chars = 5  head = `Ver.` )
      ( name = 'CHANGED_BY' chars = 12 head = `Changed by` )
      ( name = 'CHANGED_AT' chars = 19 head = `Changed on` ) ).

    DATA lv_at TYPE i.

    LOOP AT lt_col INTO DATA(ls_col).
      APPEND VALUE dfies( tabname   = 'ZSQLR_QUERY'
                          fieldname = ls_col-name
                          position  = sy-tabix
                          offset    = lv_at
                          intlen    = ls_col-chars * 2
                          leng      = ls_col-chars
                          outputlen = ls_col-chars
                          inttype   = 'C'
                          datatype  = 'CHAR'
                          langu     = sy-langu
                          reptext   = ls_col-head
                          scrtext_s = ls_col-head
                          scrtext_m = ls_col-head
                          scrtext_l = ls_col-head ) TO lt_field.
      lv_at = lv_at + ls_col-chars * 2.
    ENDLOOP.

    DATA lt_return TYPE STANDARD TABLE OF ddshretval.
    CALL FUNCTION 'F4IF_INT_TABLE_VALUE_REQUEST'
      EXPORTING
        retfield        = 'QUERY_NAME'
        dynpprog        = sy-repid
        dynpnr          = sy-dynnr
        dynprofield     = 'P_QUERY'
        value_org       = 'S'
      TABLES
        field_tab       = lt_field
        value_tab       = lt_pick
        return_tab      = lt_return
      EXCEPTIONS
        parameter_error = 1
        no_values_found = 2
        OTHERS          = 3.

    IF sy-subrc <> 0.
      MESSAGE |The list of saved queries could not be shown ({ lines( lt_pick ) } are there).| TYPE 'S' DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

    READ TABLE lt_return INTO DATA(ls_return) INDEX 1.
    IF sy-subrc = 0.
      p_query = ls_return-fieldval.
    ENDIF.

  ENDMETHOD.


  METHOD pick_file.

    " Only for a file on this machine. A server path is not something the
    " front end can browse, and offering it a dialog there would hand back
    " a path that does not exist on the host.
    IF p_srv = abap_true.
      MESSAGE 'This is a path on the application server. AL11 lists the directories it knows.' TYPE 'S'.
      RETURN.
    ENDIF.

    DATA lv_name TYPE string.
    DATA lv_path TYPE string.
    DATA lv_full TYPE string.

    cl_gui_frontend_services=>file_save_dialog(
      EXPORTING
        default_file_name = zcl_sqlr_out=>file_name( iv_name   = CONV string( p_query )
                                                     iv_format = CONV string( p_fmt ) )
      CHANGING
        filename          = lv_name
        path              = lv_path
        fullpath          = lv_full
      EXCEPTIONS
        OTHERS            = 1 ).

    IF sy-subrc = 0 AND lv_full IS NOT INITIAL.
      p_file = lv_full.
    ENDIF.

  ENDMETHOD.


  METHOD approved.

    CLEAR ev_sql.

    DATA(lv_sql) = iv_sql.
    IF lv_sql IS INITIAL.
      say( VALUE #( code = 'NO_STATEMENT'
                    what = 'Running the query.'
                    why  = 'There is no statement to run.'
                    fix  = 'Write one in the editor, or name a saved query -- a scheduled run has no editor and reads the statement by name.' ) ).
      RETURN.
    ENDIF.

    DATA(ls_guard) = zcl_sqlr_guard=>check( lv_sql ).
    IF ls_guard-ok = abap_false.
      say( ls_guard-diag ).
      RETURN.
    ENDIF.

    DATA(ls_allow) = zcl_sqlr_allow=>check( ls_guard-sources ).
    IF ls_allow-ok = abap_false.
      say( ls_allow-diag ).
      RETURN.
    ENDIF.

    " Cross-client means one thing: the client rewrite is skipped and the
    " statement runs as typed, so a client-dependent table is read in
    " every client. The guard and the table list have already had their
    " say above -- reading every client widens which rows, never which
    " tables. The authorisation is asked here, before anything reaches the
    " database, and asked again by ZCL_SQLR_OUT for a file or a mail.
    IF p_cross = abap_true.
      DATA(ls_client) = zcl_sqlr_auth=>may_read_every_client( ).
      IF ls_client-ok = abap_false.
        say( ls_client-diag ).
        RETURN.
      ENDIF.
      ev_sql = lv_sql.
    ELSE.
      ev_sql = zcl_sqlr_client=>for_current_client( iv_sql     = lv_sql
                                                    it_sources = ls_guard-sources ).
    ENDIF.

    " What the log keeps is the statement as it was **sent** -- after the
    " client rewrite, not as it was typed. What ran is what an auditor
    " needs; what was typed is a different and less useful question.
    gs_run-statement = ev_sql.

    rv_ok = abap_true.

  ENDMETHOD.


  METHOD check.

    DATA lv_sql TYPE string.

    IF cleared_to_run( ) = abap_false.
      RETURN.
    ENDIF.

    " What is on the screen now, which is not gt_last: remember( ) runs
    " after command( ), so the draft is one round trip behind at this
    " point. Where there is no control to read, the saved query the name
    " refers to is the only statement there is.
    DATA(lv_typed) = statement( ).
    IF lv_typed IS INITIAL.
      lv_typed = statement_to_run( ).
    ENDIF.

    IF approved( EXPORTING iv_sql = lv_typed
                 IMPORTING ev_sql = lv_sql ) = abap_false.
      RETURN.
    ENDIF.

    DATA(ls_check) = zcl_sqlr_exec=>describe( lv_sql ).
    IF ls_check-ok = abap_false.
      say( ls_check-diag ).
      RETURN.
    ENDIF.

    DATA(lv_columns) = ``.
    LOOP AT ls_check-columns INTO DATA(ls_column).
      lv_columns = COND #( WHEN lv_columns IS INITIAL THEN ls_column-name
                           ELSE |{ lv_columns }, { ls_column-name }| ).
    ENDLOOP.
    MESSAGE |Clean. { lines( ls_check-columns ) } column(s): { lv_columns }| TYPE 'S'.

  ENDMETHOD.


  METHOD refused_at_the_door.

    say( VALUE #(
      code = 'NOT_AUTHORISED'
      what = 'Opening SQL reporting.'
      why  = |{ sy-uname } holds no authorisation for this tool at all.|
      fix  = 'Ask for Z_SQLR_RUN: activity 16 to run queries, 03 to see the table list, 02 to change it.' ) ).

  ENDMETHOD.


  METHOD cleared_to_run.

    DATA(ls_may) = zcl_sqlr_auth=>may_run( ).
    IF ls_may-ok = abap_true.
      rv_ok = abap_true.
      RETURN.
    ENDIF.

    say( ls_may-diag ).

  ENDMETHOD.


  METHOD command.

    CASE iv_ucomm.

      WHEN 'FC01'.   " Run
        " F8 reaches the run through START-OF-SELECTION, which is after
        " this event and therefore after remember( ). A button does not:
        " it arrives here, one round trip before the draft is refreshed,
        " so the statement has to be read first or the run would use the
        " one from the previous trip through the screen.
        remember( ).
        execute( ).

      WHEN 'FC02'.   " Check
        check( ).
      WHEN 'FC03'.   " Save
        save_query( ).
      WHEN 'FC04'.   " Open
        open_query( ).
      WHEN 'FC05'.   " Admin
        admin( ).

    ENDCASE.

  ENDMETHOD.


  METHOD admin.

    " Retiring a query lives here rather than on the toolbar. It is rare,
    " it is destructive, and the slot it used to hold is worth more to
    " Run -- which is the one thing on this screen everybody presses.
    DATA lt_options TYPE STANDARD TABLE OF spopli.
    APPEND VALUE #( varoption = 'Who may read which tables' )    TO lt_options.
    APPEND VALUE #( varoption = 'What has been run' )            TO lt_options.
    APPEND VALUE #( varoption = 'Who changed the table lists' )  TO lt_options.
    APPEND VALUE #( varoption = 'Retire the query named above' ) TO lt_options.
    APPEND VALUE #( varoption = 'Close' )                        TO lt_options.

    DATA lv_answer TYPE c LENGTH 1.
    CALL FUNCTION 'POPUP_TO_DECIDE_LIST'
      EXPORTING
        textline1          = 'The table lists, and the logs of runs and of changes to them.'
        titel              = 'SQL reporting'
      IMPORTING
        answer             = lv_answer
      TABLES
        t_spopli           = lt_options
      EXCEPTIONS
        not_enough_answers = 1
        too_much_answers   = 2
        too_much_marks     = 3
        OTHERS             = 4.

    IF sy-subrc <> 0 OR lv_answer CA 'A' OR lv_answer IS INITIAL.
      RETURN.
    ENDIF.

    CASE lv_answer.
      WHEN '1'.
        maintain_tables( ).
      WHEN '2'.
        show_log( ).
      WHEN '3'.
        show_grant_log( ).
      WHEN '4'.
        delete_query( ).
    ENDCASE.

  ENDMETHOD.


  METHOD show_log.

    " Straight to the application log, already filtered on this tool's
    " object and subobject -- which is what "jump to the right
    " subobject" means. Anybody who would rather start from SLG1 can:
    " the object is ZSQLR.
    DATA(ls_may) = zcl_sqlr_auth=>may_read_log( ).
    IF ls_may-ok = abap_false.
      say( ls_may-diag ).
      RETURN.
    ENDIF.

    zcl_sqlr_log=>show( iv_from = CONV d( sy-datum - 30 ) ).

  ENDMETHOD.


  METHOD maintain_tables.

    DATA(ls_see) = zcl_sqlr_auth=>may_see_tables( ).
    IF ls_see-ok = abap_false.
      say( ls_see-diag ).
      RETURN.
    ENDIF.

    gv_grid_edit = zcl_sqlr_auth=>may_change_tables( )-ok.

    " Whatever this session cached is about to be wrong.
    zcl_sqlr_allow=>forget( ).
    fill_grid( ).

    " The user and the table are referred to the dictionary, which is what
    " gives the grid their value help: F4 on a user lists users, F4 on a
    " table lists tables. A pattern such as ZSALES_* is still accepted --
    " the reference is for help, not for a check.
    DATA(lt_fcat) = VALUE lvc_t_fcat(
      ( fieldname = 'REMOVE'     inttype = 'C' intlen = 1 checkbox = abap_true
        edit = gv_grid_edit coltext = 'Remove' outputlen = 8 no_out = xsdbool( gv_grid_edit = abap_false ) )
      ( fieldname = 'UNAME'      ref_table = 'ZSQLR_GRANT' ref_field = 'UNAME'
        edit = gv_grid_edit coltext = 'User (* = everybody)' outputlen = 20 )
      ( fieldname = 'TABNAME'    ref_table = 'ZSQLR_GRANT' ref_field = 'TABNAME'
        edit = gv_grid_edit coltext = 'Table or pattern' outputlen = 30 )
      " No dictionary reference here: REASON is a built-in CHAR with no
      " lower-case flag, and a reference would override LOWERCASE below.
      ( fieldname = 'REASON'     inttype = 'C' intlen = 120 dd_outlen = 120
        edit = gv_grid_edit coltext = 'Why (optional)' outputlen = 50
        lowercase = abap_true )
      ( fieldname = 'CHANGED_BY' ref_table = 'ZSQLR_GRANT' ref_field = 'CHANGED_BY'
        coltext = 'Changed by' outputlen = 12 )
      ( fieldname = 'CHANGED_AT' inttype = 'C' intlen = 19 outputlen = 19
        coltext = 'Changed on' ) ).

    DATA(lv_title) = COND lvc_title(
      WHEN gv_grid_edit = abap_true
      THEN 'Type new grants on the empty lines, tick Remove to drop one, then Save'
      ELSE 'Read-only: changing these lists needs Z_SQLR_RUN activity 02' ).

    " Cell edits reach the program before the user command does, or Save
    " would store the grid as it was before the last field was typed into.
    DATA(ls_settings) = VALUE lvc_s_glay( edt_cll_cb = abap_true ).
    DATA(ls_layout)   = VALUE lvc_s_layo( zebra = abap_true ).

    " Back, Exit and Cancel come to grid_command( ) before the grid closes,
    " so unsaved edits can be caught rather than dropped without a word.
    DATA(lt_exit) = VALUE slis_t_event_exit(
      ( ucomm = '&F03' before = abap_true )
      ( ucomm = '&F12' before = abap_true )
      ( ucomm = '&F15' before = abap_true ) ).

    CALL FUNCTION 'REUSE_ALV_GRID_DISPLAY_LVC'
      EXPORTING
        i_callback_program      = sy-repid
        i_callback_user_command = 'GRID_USER_COMMAND'
        i_grid_title            = lv_title
        i_grid_settings         = ls_settings
        is_layout_lvc           = ls_layout
        it_fieldcat_lvc         = lt_fcat
        it_event_exit           = lt_exit
      TABLES
        t_outtab                = gt_grid
      EXCEPTIONS
        program_error           = 1
        OTHERS                  = 2.
    IF sy-subrc <> 0.
      MESSAGE 'The table lists could not be shown.' TYPE 'S' DISPLAY LIKE 'E'.
    ENDIF.

  ENDMETHOD.


  METHOD fill_grid.

    gt_grid = CORRESPONDING #( zcl_sqlr_allow=>rows( ) ).
    IF gv_grid_edit = abap_true.
      DO c_blank_rows TIMES.
        APPEND INITIAL LINE TO gt_grid.
      ENDDO.
    ENDIF.

  ENDMETHOD.


  METHOD grid_command.

    " The cell the cursor is still in has not been handed over yet -- in a
    " browser it goes with the next round trip, not with the button press --
    " so ask the grid for it before reading the table, whatever was pressed.
    DATA lo_grid TYPE REF TO cl_gui_alv_grid.
    CALL FUNCTION 'GET_GLOBALS_FROM_SLVC_FULLSCR'
      IMPORTING
        e_grid = lo_grid.
    IF lo_grid IS BOUND.
      lo_grid->check_changed_data( ).
    ENDIF.

    CASE iv_ucomm.
      WHEN '&F03' OR '&F12' OR '&F15'.
        " Called before the grid closes. Clearing EXIT keeps it open.
        IF gv_grid_edit = abap_true AND grid_changed( ) = abap_true.
          DATA lv_answer TYPE c LENGTH 1.
          CALL FUNCTION 'POPUP_TO_CONFIRM'
            EXPORTING
              titlebar              = 'Unsaved changes'
              text_question         = 'The table lists have changes that are not saved. Leave without saving them?'
              text_button_1         = 'Leave'
              text_button_2         = 'Stay'
              default_button        = '2'
              display_cancel_button = abap_false
            IMPORTING
              answer                = lv_answer
            EXCEPTIONS
              OTHERS                = 1.
          IF sy-subrc <> 0 OR lv_answer <> '1'.
            cs_selfield-exit = abap_false.
          ENDIF.
        ENDIF.
        RETURN.
      WHEN '&DATA_SAVE'.
      WHEN OTHERS.
        RETURN.
    ENDCASE.

    IF gv_grid_edit = abap_false.
      MESSAGE 'You may see these lists but not change them. That needs Z_SQLR_RUN activity 02.' TYPE 'S'.
      RETURN.
    ENDIF.

    " The whole grid goes in; ZCL_SQLR_ALLOW works out what changed, checks
    " every row before writing any, and records the change in SLG1 in the
    " same unit of work -- or refuses and saves nothing. A ticked row is
    " simply left out: what is not handed over is what store( ) deactivates.
    " Empty lines it skips on its own.
    DATA(lt_keep) = VALUE zcl_sqlr_allow=>tt_row(
      FOR ls_row IN gt_grid WHERE ( remove = abap_false )
      ( CORRESPONDING #( ls_row ) ) ).

    DATA(ls_saved) = zcl_sqlr_allow=>store( lt_keep ).
    IF ls_saved-ok = abap_false.
      say( ls_saved-diag ).
      RETURN.
    ENDIF.

    fill_grid( ).
    cs_selfield-refresh    = abap_true.
    cs_selfield-row_stable = abap_true.
    cs_selfield-col_stable = abap_true.

    IF ls_saved-added = 0 AND ls_saved-removed = 0 AND ls_saved-changed = 0.
      MESSAGE 'Nothing had changed. Nothing was saved.' TYPE 'S'.
    ELSE.
      MESSAGE |Saved: { ls_saved-added } added, { ls_saved-removed } removed, | &&
              |{ ls_saved-changed } with a new reason. Admin shows the record.| TYPE 'S'.
    ENDIF.

  ENDMETHOD.


  METHOD grid_changed.

    " What the grid would store against what is stored, on the three
    " columns a person edits. Upper case both sides for the names, as
    " store( ) does; the reason is compared as typed.
    TYPES: BEGIN OF ty_cmp,
             uname   TYPE xubname,
             tabname TYPE tabname,
             reason  TYPE c LENGTH 120,
           END OF ty_cmp.
    DATA lt_grid TYPE SORTED TABLE OF ty_cmp WITH NON-UNIQUE KEY uname tabname reason.
    DATA lt_db   LIKE lt_grid.

    LOOP AT gt_grid INTO DATA(ls_row)
         WHERE remove = abap_false AND ( uname IS NOT INITIAL OR tabname IS NOT INITIAL ).
      INSERT VALUE #( uname   = to_upper( condense( ls_row-uname ) )
                      tabname = to_upper( condense( ls_row-tabname ) )
                      reason  = ls_row-reason ) INTO TABLE lt_grid.
    ENDLOOP.
    LOOP AT zcl_sqlr_allow=>rows( ) INTO DATA(ls_db).
      INSERT VALUE #( uname   = to_upper( condense( ls_db-uname ) )
                      tabname = to_upper( condense( ls_db-tabname ) )
                      reason  = ls_db-reason ) INTO TABLE lt_db.
    ENDLOOP.

    rv_changed = xsdbool( lt_grid <> lt_db ).

  ENDMETHOD.


  METHOD show_grant_log.

    DATA(ls_may) = zcl_sqlr_auth=>may_read_log( ).
    IF ls_may-ok = abap_false.
      say( ls_may-diag ).
      RETURN.
    ENDIF.

    " No date limit: this is an audit trail, and the change somebody asks
    " about is as likely to be last year's as last week's.
    zcl_sqlr_log=>show( iv_subobject = zcl_sqlr_log=>c_sub_grant ).

  ENDMETHOD.


  METHOD statement_to_run.

    IF gt_last IS NOT INITIAL.
      CONCATENATE LINES OF gt_last INTO rv_sql SEPARATED BY cl_abap_char_utilities=>newline.
      RETURN.
    ENDIF.

    " No editor: this is a job step running a variant. The variant carries
    " the name; the store carries the statement.
    IF p_query IS INITIAL.
      RETURN.
    ENDIF.

    DATA lt_text TYPE rswsourcet.
    IF zcl_sqlr_query=>load( EXPORTING iv_name = CONV string( p_query )
                             IMPORTING et_text = lt_text ) = abap_false.
      RETURN.
    ENDIF.

    CONCATENATE LINES OF lt_text INTO rv_sql SEPARATED BY cl_abap_char_utilities=>newline.

  ENDMETHOD.


  METHOD target.
    rv_target = COND #( WHEN p_local = abap_true THEN zcl_sqlr_out=>c_local
                        WHEN p_srv   = abap_true THEN zcl_sqlr_out=>c_server
                        WHEN p_mail  = abap_true THEN zcl_sqlr_out=>c_mail
                        ELSE zcl_sqlr_out=>c_grid ).
  ENDMETHOD.


  METHOD recipients.
    LOOP AT s_rcpt INTO DATA(ls_range) WHERE low IS NOT INITIAL.
      APPEND CONV string( ls_range-low ) TO rt_address.
    ENDLOOP.
  ENDMETHOD.


  METHOD execute.

    " Opened here and closed here, with everything in between free to
    " leave by any door it likes. That is the whole reason the run is a
    " method of its own: there are nine ways out of it and every one of
    " them has to end up in the log.
    gs_run             = zcl_sqlr_log=>begin( ).
    gs_run-query_name  = p_query.
    gs_run-target      = target( ).
    gs_run-out_format  = COND #( WHEN target( ) = zcl_sqlr_out=>c_grid THEN space ELSE p_fmt ).
    gs_run-client_mode = COND #( WHEN p_cross = abap_true
                                 THEN zcl_sqlr_auth=>c_every_client
                                 ELSE zcl_sqlr_auth=>c_this_client ).
    gs_run-where_to    = COND #( WHEN target( ) = zcl_sqlr_out=>c_mail
                                 THEN concat_lines_of( table = recipients( ) sep = `, ` )
                                 ELSE p_file ).

    run_now( ).

    zcl_sqlr_log=>finish( gs_run ).

    " Whatever happened, the screen is about to be drawn again and the
    " editor will have to be put back. See build_screen( ).
    gv_came_back = abap_true.

  ENDMETHOD.


  METHOD run_now.

    DATA lv_sql TYPE string.

    IF cleared_to_run( ) = abap_false.
      RETURN.
    ENDIF.

    " Kept as typed, beside the rewritten one approved( ) hands back. The
    " rewrite is what runs and what the log keeps; the typed statement is
    " what a person wrote and can read, so it is the one a mail carries.
    DATA(lv_typed) = statement_to_run( ).

    IF approved( EXPORTING iv_sql = lv_typed
                 IMPORTING ev_sql = lv_sql ) = abap_false.
      RETURN.
    ENDIF.

    DATA(lv_target) = target( ).

    " Where a result may go is its own right, and the one that matters most:
    " reading a table inside SAP and mailing it out of SAP are not the same
    " act. Checked here and again in ZCL_SQLR_OUT, so a caller that is not
    " this screen cannot skip it.
    DATA(ls_channel) = zcl_sqlr_auth=>may_send_to( zcl_sqlr_auth=>channel_of( lv_target ) ).
    IF ls_channel-ok = abap_false.
      say( ls_channel-diag ).
      RETURN.
    ENDIF.

    IF lv_target = zcl_sqlr_out=>c_grid.

      IF zcl_sqlr_out=>front_end( ) = abap_false.
        say( VALUE #( code = 'NO_GRID_IN_BATCH'
                      what = 'Showing the result in a grid.'
                      why  = 'This is running without a front end, and a grid needs a screen to be drawn on.'
                      fix  = 'Schedule it to a file on the application server or to e-mail. Both run unattended.' ) ).
        RETURN.
      ENDIF.

      DATA(ls_run) = zcl_sqlr_exec=>run( iv_sql      = lv_sql
                                         iv_max_rows = p_max ).
      IF ls_run-ok = abap_false.
        say( ls_run-diag ).
        RETURN.
      ENDIF.

      IF ls_run-rows = 0.
        gs_run-outcome = zcl_sqlr_log=>c_nothing.
        MESSAGE 'The statement ran and returned no rows.' TYPE 'S'.
        RETURN.
      ENDIF.

      gs_run-outcome   = zcl_sqlr_log=>c_done.
      gs_run-rows      = ls_run-rows.
      gs_run-truncated = ls_run-truncated.

      show( ir_data      = ls_run-data
            iv_rows      = ls_run-rows
            iv_truncated = ls_run-truncated ).
      RETURN.

    ENDIF.

    DATA(ls_out) = zcl_sqlr_out=>deliver(
      iv_sql       = lv_sql
      iv_target    = lv_target
      iv_format    = CONV string( p_fmt )
      iv_separator = p_sep
      iv_path      = CONV string( p_file )
      it_recipient = recipients( )
      iv_subject   = CONV string( p_subj )
      iv_name      = CONV string( p_query )
      iv_max_rows  = p_max
      iv_attach_sql = p_sqlatt
      iv_statement = lv_typed
      iv_every_client = p_cross ).

    IF ls_out-ok = abap_false.
      say( ls_out-diag ).
      RETURN.
    ENDIF.

    gs_run-outcome   = COND #( WHEN ls_out-rows = 0
                               THEN zcl_sqlr_log=>c_nothing
                               ELSE zcl_sqlr_log=>c_done ).
    gs_run-rows      = ls_out-rows.
    gs_run-bytes     = ls_out-bytes.
    gs_run-truncated = ls_out-truncated.
    gs_run-message   = ls_out-note.

    MESSAGE ls_out-note TYPE 'S'.

    " A job log that only says "finished" is a job log nobody can audit.
    IF zcl_sqlr_out=>front_end( ) = abap_false.
      MESSAGE |{ ls_out-rows } row(s), { ls_out-bytes } bytes. { ls_out-note }| TYPE 'I'.
    ENDIF.

  ENDMETHOD.


  METHOD layout_handle.

    " One layout namespace per query, not one per program.
    "
    " An ALV layout names the columns it orders, sums and hides. The
    " columns of one query are not the columns of another, so a single
    " namespace would offer one query's layout to another and
    " draw an empty grid -- the feature quietly breaking the moment it is
    " used for the second time. The name is folded into four characters,
    " which is all the handle field holds.
    IF p_query IS INITIAL.
      rv_handle = '0000'.
      RETURN.
    ENDIF.

    DATA lv_byte TYPE x LENGTH 1.
    DATA lv_hash TYPE i.
    DATA lv_fold TYPE x LENGTH 2.
    DATA lv_at   TYPE i.

    TRY.
        DATA(lv_bytes) = cl_abap_conv_codepage=>create_out( )->convert( CONV string( p_query ) ).
      CATCH cx_root.
        rv_handle = '0000'.
        RETURN.
    ENDTRY.

    DO xstrlen( lv_bytes ) TIMES.
      lv_at   = sy-index - 1.
      lv_byte = lv_bytes+lv_at(1).
      lv_hash = ( lv_hash * 31 + lv_byte ) MOD 65536.
    ENDDO.

    lv_fold   = lv_hash.
    rv_handle = lv_fold.

  ENDMETHOD.


  METHOD show.

    FIELD-SYMBOLS <lt_rows> TYPE STANDARD TABLE.
    ASSIGN ir_data->* TO <lt_rows>.
    IF <lt_rows> IS NOT ASSIGNED.
      RETURN.
    ENDIF.

    DATA lo_alv TYPE REF TO cl_salv_table.
    TRY.
        cl_salv_table=>factory( IMPORTING r_salv_table = lo_alv
                                CHANGING  t_table      = <lt_rows> ).

        DATA(lo_functions) = lo_alv->get_functions( ).
        lo_functions->set_all( ).

        " set_all already turns the export group on -- CL_SALV_FUNCTIONS_LIST
        " calls set_group_export, which is what puts Spreadsheet, Local file
        " and Send on the list. Saying it again here costs nothing and makes
        " the intent findable: somebody asked where Excel had gone, and the
        " answer was that it is in the menu (List -> Export -> Spreadsheet),
        " not that it was switched off.
        lo_functions->set_group_export( abap_true ).
        lo_functions->set_export_spreadsheet( abap_true ).
        lo_functions->set_export_localfile( abap_true ).

        " Without a layout key the grid has no Choose, Change, Save or
        " Manage layout -- SALV hides those four rather than greying them,
        " because it has nowhere to store what they would produce. That is
        " what "not a full-function grid" looked like: the four buttons
        " people use most, missing, with no explanation on the screen.
        DATA(lo_layout) = lo_alv->get_layout( ).
        lo_layout->set_key( VALUE #( report = sy-repid
                                     handle = layout_handle( ) ) ).
        lo_layout->set_save_restriction( if_salv_c_layout=>restrict_none ).
        lo_layout->set_default( abap_true ).

        " And without a selection mode the column buttons have nothing to
        " act on: Sort ascending with no column marked does nothing at all,
        " which reads as a broken toolbar rather than a missing click.
        lo_alv->get_selections( )->set_selection_mode(
          if_salv_c_selection_mode=>row_column ).

        DATA(lo_columns) = lo_alv->get_columns( ).
        lo_columns->set_optimize( ).
        zcl_sqlr_out=>label_columns( lo_columns ).

        DATA(lo_display) = lo_alv->get_display_settings( ).
        lo_display->set_striped_pattern( abap_true ).

        " The header is where the difference between "the answer" and "the
        " first part of the answer" is stated. A grid that quietly holds the
        " first 500 of 40,000 rows is how somebody reports a wrong total.
        "
        " And whether it is this client's answer. A result read across every
        " client that looks like this client's is how a figure gets counted
        " once per client.
        DATA(lv_head) = COND string(
          WHEN iv_truncated = abap_true
          THEN |First { iv_rows } rows -- there are more. Send it to a file for all of them.|
          ELSE |{ iv_rows } row(s).| ).
        IF p_cross = abap_true.
          lv_head = |Every client. { lv_head }|.
        ENDIF.
        lo_display->set_list_header( CONV lvc_title( lv_head ) ).

        lo_alv->display( ).

      CATCH cx_salv_error INTO DATA(lx).
        MESSAGE lx->get_text( ) TYPE 'S' DISPLAY LIKE 'E'.
    ENDTRY.

  ENDMETHOD.


  METHOD say.

    " Every refusal inside a run passes through here, which makes this the
    " one place the log has to learn why one stopped. Nothing is written
    " yet -- the row goes out when the run ends, and a refusal is an
    " ending. Outside a run this writes into a structure nobody reads.
    gs_run-outcome = zcl_sqlr_log=>c_refused.
    gs_run-code    = is_diag-code.
    gs_run-message = is_diag-why.

    " Three parts, three lines, as everything in this programme reports a
    " failure: what we were doing, why it stopped, what to do about it.
    " A job has nobody to acknowledge a popup, so there it is three lines
    " of job log instead -- the same three, in the same order.
    IF zcl_sqlr_out=>front_end( ) = abap_false.
      MESSAGE is_diag-what TYPE 'I'.
      MESSAGE is_diag-why  TYPE 'I'.
      MESSAGE is_diag-fix  TYPE 'I'.
      RETURN.
    ENDIF.

    CALL FUNCTION 'POPUP_TO_INFORM'
      EXPORTING
        titel = 'SQL reporting'
        txt1  = CONV char80( is_diag-what )
        txt2  = CONV char80( is_diag-why )
        txt3  = CONV char80( is_diag-fix ).

  ENDMETHOD.

ENDCLASS.


INITIALIZATION.

  " Each fits the COMMENT width declared beside its field -- a longer text
  " is cut, not wrapped.
  c_qname = 'Query name'.
  c_qdesc = 'Query description'.
  c_grid  = 'Grid on screen'.
  c_local = 'File on this PC'.
  c_srv   = 'File on server'.
  c_mail  = 'E-mail'.
  c_fmt   = 'Format'.
  c_sep   = 'Separator'.
  c_max   = 'Max rows (0=all)'.
  c_hl    = 'Highlight as'.
  c_cross = 'Cross-client'.
  c_sqlatt = 'Attach the SQL statement'.
  c_to     = 'To'.
  c_subj   = 'Subject'.

  " Icons with tooltips, because five words on a button say less than one
  " picture and a sentence behind it.
  "
  " Run is first and is a button of its own, even though F8 already runs
  " the report and is what a scheduled variant triggers. In SAP GUI for
  " HTML the standard Execute is drawn at the bottom right of the screen,
  " away from everything else on this one, and the most-pressed control
  " on a screen should not be the one that takes longest to find.
  "
  " Each quickinfo has to fit 60 characters. Longer is not an error, it is
  " worse: the field takes the first 60 and the tooltip ends mid-word.
  DATA gs_button TYPE smp_dyntxt.

  gs_button = VALUE #( icon_id   = icon_execute_object
                       icon_text = 'Run'
                       quickinfo = 'Run the statement. F8 does the same.' ).
  sscrfields-functxt_01 = gs_button.

  gs_button = VALUE #( icon_id   = icon_check
                       icon_text = 'Check'
                       quickinfo = 'Ask the database to parse it. Nothing is read.' ).
  sscrfields-functxt_02 = gs_button.

  gs_button = VALUE #( icon_id   = icon_system_save
                       icon_text = 'Save'
                       quickinfo = 'Save the statement under the name above' ).
  sscrfields-functxt_03 = gs_button.

  gs_button = VALUE #( icon_id   = icon_open_folder
                       icon_text = 'Open'
                       quickinfo = 'Load the saved query named above (F4 lists them)' ).
  sscrfields-functxt_04 = gs_button.

  gs_button = VALUE #( icon_id   = icon_tools
                       icon_text = 'Admin'
                       quickinfo = 'Tables, the log, and retiring a saved query' ).
  sscrfields-functxt_05 = gs_button.

  " Nobody with no rights at all should get as far as the editor. The
  " three parts go out first and the program ends after them, rather than
  " the other way round: a screen that closes without saying why is the
  " failure this programme is written not to produce.
  IF zcl_sqlr_auth=>anything( ) = abap_false.
    lcl_app=>refused_at_the_door( ).
    LEAVE PROGRAM.
  ENDIF.


AT SELECTION-SCREEN OUTPUT.
  lcl_app=>offer_formats( ).
  lcl_app=>build_screen( ).
  lcl_app=>apply_highlighting( ).
  lcl_app=>arrange_screen( ).

AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_query.
  lcl_app=>pick_query( ).

AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_file.
  lcl_app=>pick_file( ).

AT SELECTION-SCREEN.
  lcl_app=>command( sscrfields-ucomm ).
  " Last, so that a query just opened is the one remembered.
  lcl_app=>remember( ).

START-OF-SELECTION.
  lcl_app=>execute( ).


*--- The grant grid calls back here, by name ----------------------------
FORM grid_user_command USING iv_ucomm    TYPE sy-ucomm
                             cs_selfield TYPE slis_selfield.
  lcl_app=>grid_command( EXPORTING iv_ucomm    = iv_ucomm
                         CHANGING  cs_selfield = cs_selfield ).
ENDFORM.
