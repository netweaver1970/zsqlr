" Rows into CSV, either into memory or straight onto the server's disk.
"
" One class, two destinations, because the difference between them is a
" single line: the bytes are either appended to an xstring or transferred
" to an open dataset. Splitting that into two classes would duplicate the
" header, the byte-order mark, the line endings and the counting, all to
" express one IF.
"
" Which destination matters for size. With a path, nothing is held: the
" package is written and released, so the extract is limited by the disk
" and not by the work process. Without one, the whole file is in memory,
" which is unavoidable -- a front-end download and a mail attachment both
" have to be complete before they can be handed over.
"
" A byte-order mark goes in front. Without it a spreadsheet opening a
" UTF-8 file guesses the code page, and the first name with an accent in
" it comes out wrong.
CLASS zcl_sqlr_sink_csv DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.

    INTERFACES zif_sqlr_sink.

    "! @parameter iv_path | A server path writes there as the rows arrive.
    "!                      Empty keeps the file in memory for the caller.
    METHODS constructor
      IMPORTING iv_separator TYPE c DEFAULT ';'
                iv_path      TYPE string OPTIONAL.

    "! The file, when it was kept in memory. Empty when it went to disk.
    METHODS content
      RETURNING VALUE(rv_content) TYPE xstring.

    METHODS bytes
      RETURNING VALUE(rv_bytes) TYPE i.

  PRIVATE SECTION.

    DATA mv_separator TYPE c LENGTH 1.
    DATA mv_path      TYPE string.
    DATA mv_open      TYPE abap_bool.
    DATA mv_content   TYPE xstring.
    DATA mv_bytes     TYPE i.
    DATA ms_diag      TYPE zcl_sqlr_guard=>ty_diag.

    METHODS put
      IMPORTING iv_bytes TYPE xstring.

    METHODS emit
      IMPORTING it_lines TYPE string_table.

ENDCLASS.


CLASS zcl_sqlr_sink_csv IMPLEMENTATION.

  METHOD constructor.
    mv_separator = iv_separator.
    mv_path      = iv_path.
  ENDMETHOD.


  METHOD content.
    rv_content = mv_content.
  ENDMETHOD.


  METHOD bytes.
    rv_bytes = mv_bytes.
  ENDMETHOD.


  METHOD zif_sqlr_sink~open.

    FIELD-SYMBOLS <ls_row> TYPE any.

    " Not an inline declaration: OPEN DATASET's MESSAGE addition will not
    " take one.
    DATA lv_msg TYPE string.

    IF mv_path IS NOT INITIAL.

      " Binary, not text: text mode picks the line ending and the code page
      " from the application server's platform, so the same query would
      " produce a different file on a different host. Here both are chosen.
      "
      " No authorisation check is written here and none is missing. OPEN
      " DATASET is checked by the kernel against S_DATASET, which is the
      " standard control for writing server files and is already somebody's
      " job to maintain. Spec 036 section 7.
      OPEN DATASET mv_path FOR OUTPUT IN BINARY MODE MESSAGE lv_msg.
      IF sy-subrc <> 0.
        ms_diag = VALUE #(
          code = 'SERVER_FILE_OPEN'
          what = |Opening { mv_path } on the application server.|
          why  = |The server refused it: { lv_msg }|
          fix  = 'Check the directory exists and that you hold S_DATASET for it. AL11 lists the directories this system knows.' ).
        RETURN.
      ENDIF.
      mv_open = abap_true.

    ENDIF.

    ASSIGN ir_row->* TO <ls_row>.
    IF <ls_row> IS NOT ASSIGNED.
      RETURN.
    ENDIF.

    put( CONV xstring( cl_abap_char_utilities=>byte_order_mark_utf8 ) ).

    emit( VALUE #( ( zcl_sqlr_csv=>header_line( is_row       = <ls_row>
                                                iv_separator = mv_separator ) ) ) ).

  ENDMETHOD.


  METHOD zif_sqlr_sink~write.

    FIELD-SYMBOLS <lt_package> TYPE STANDARD TABLE.
    FIELD-SYMBOLS <ls_row>     TYPE any.

    IF ms_diag-code IS NOT INITIAL.
      RETURN.
    ENDIF.

    ASSIGN ir_package->* TO <lt_package>.
    IF <lt_package> IS NOT ASSIGNED.
      RETURN.
    ENDIF.

    DATA lt_lines TYPE string_table.
    LOOP AT <lt_package> ASSIGNING <ls_row>.
      APPEND zcl_sqlr_csv=>row_line( is_row       = <ls_row>
                                     iv_separator = mv_separator ) TO lt_lines.
    ENDLOOP.

    emit( lt_lines ).

  ENDMETHOD.


  METHOD zif_sqlr_sink~close.
    IF mv_open = abap_true.
      CLOSE DATASET mv_path.
      CLEAR mv_open.
    ENDIF.
  ENDMETHOD.


  METHOD zif_sqlr_sink~failure.
    rs_diag = ms_diag.
  ENDMETHOD.


  METHOD emit.

    IF it_lines IS INITIAL.
      RETURN.
    ENDIF.

    " Built in one pass. Appending line by line to a growing string copies
    " the string each time, and at ten thousand lines a package that is the
    " slowest thing in the programme.
    DATA lv_text TYPE string.
    CONCATENATE LINES OF it_lines INTO lv_text
                SEPARATED BY cl_abap_char_utilities=>cr_lf.
    lv_text = |{ lv_text }{ cl_abap_char_utilities=>cr_lf }|.

    TRY.
        put( cl_abap_conv_codepage=>create_out( )->convert( lv_text ) ).
      CATCH cx_root INTO DATA(lx).
        ms_diag = VALUE #(
          code = 'ENCODING'
          what = 'Writing the rows as UTF-8.'
          why  = lx->get_text( )
          fix  = 'A character in the data could not be encoded. Keep the message and tell whoever maintains the tool.' ).
    ENDTRY.

  ENDMETHOD.


  METHOD put.

    DATA(lv_length) = xstrlen( iv_bytes ).
    IF lv_length = 0.
      RETURN.
    ENDIF.

    IF mv_open = abap_true.
      TRANSFER iv_bytes TO mv_path LENGTH lv_length.
    ELSE.
      CONCATENATE mv_content iv_bytes INTO mv_content IN BYTE MODE.
    ENDIF.

    mv_bytes = mv_bytes + lv_length.

  ENDMETHOD.

ENDCLASS.
