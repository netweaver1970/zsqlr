" A row of unknown shape, as a line of CSV.
"
" Nothing here is localised, and that is the point. A file leaving this
" tool is read by a machine somewhere else -- a spreadsheet, a load
" programme, a script -- and it must not change shape because the person
" who ran it has a German date format or a comma for a decimal point. So:
" ISO dates, a full stop for decimals, the minus sign in front, and
" quoting only where quoting is needed.
"
" The two rules that are easy to get wrong, and are tested:
"
"  * ABAP writes a negative packed number with the sign at the END --
"    1234.56-. Nothing outside ABAP reads that as a number; Excel reads
"    it as text and quietly ruins the column's total.
"
"  * A value holding the separator, a quotation mark or a line break must
"    be quoted, and a quotation mark inside a quoted value is doubled.
"    Miss it and one address with a comma in it shifts every column after
"    it, on that row only, which is the kind of error nobody sees.
CLASS zcl_sqlr_csv DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.

    "! One value, as text a machine elsewhere will read back correctly.
    CLASS-METHODS text_of
      IMPORTING iv_value       TYPE any
      RETURNING VALUE(rv_text) TYPE string.

    "! Quotes it, but only when it has to be quoted.
    CLASS-METHODS quoted
      IMPORTING iv_text        TYPE string
                iv_separator   TYPE c
      RETURNING VALUE(rv_text) TYPE string.

    "! The column names, in the order the query asked for them.
    CLASS-METHODS header_line
      IMPORTING is_row         TYPE any
                iv_separator   TYPE c
      RETURNING VALUE(rv_line) TYPE string.

    CLASS-METHODS row_line
      IMPORTING is_row         TYPE any
                iv_separator   TYPE c
      RETURNING VALUE(rv_line) TYPE string.

ENDCLASS.


CLASS zcl_sqlr_csv IMPLEMENTATION.

  METHOD text_of.

    DATA lv_date TYPE d.
    DATA lv_time TYPE t.
    DATA lv_len  TYPE i.

    DATA(lo_type) = cl_abap_typedescr=>describe_by_data( iv_value ).

    CASE lo_type->type_kind.

      WHEN cl_abap_typedescr=>typekind_date.
        lv_date = iv_value.
        " An empty date is empty, not the year nought. A spreadsheet shown
        " 0000-00-00 puts it in the column as text and the column stops
        " sorting as dates.
        IF lv_date IS INITIAL.
          RETURN.
        ENDIF.
        rv_text = |{ lv_date DATE = ISO }|.

      WHEN cl_abap_typedescr=>typekind_time.
        lv_time = iv_value.
        rv_text = |{ lv_time TIME = ISO }|.

      WHEN OTHERS.
        " The plain conversion. For character fields it drops the padding
        " and keeps everything else, including the inside spaces -- which
        " is why CONDENSE is not applied to them: a description with two
        " spaces in it is not this programme's to tidy.
        rv_text = iv_value.

        " Numbers are different, and both halves of the difference were
        " found by the tests rather than guessed at. ABAP keeps the sign
        " position on the value: a trailing blank where a positive number's
        " sign would be, and a trailing minus for a negative one. Neither
        " is read by anything outside ABAP -- the minus turns a column of
        " money into text in a spreadsheet, and the blank is simply dirt in
        " the file. The type kinds are single characters: I, b, s and 8 for
        " the integers, P packed, F float, a and e the two decimal floats.
        IF lo_type->type_kind CA 'IbsP8Fae'.
          rv_text = condense( rv_text ).
          lv_len  = strlen( rv_text ).
          IF lv_len > 0 AND substring( val = rv_text off = lv_len - 1 len = 1 ) = '-'.
            rv_text = |-{ substring( val = rv_text len = lv_len - 1 ) }|.
          ENDIF.
        ENDIF.

    ENDCASE.

  ENDMETHOD.


  METHOD quoted.

    rv_text = iv_text.

    DATA(lv_special) = |{ iv_separator }"{ cl_abap_char_utilities=>cr_lf }{ cl_abap_char_utilities=>horizontal_tab }|.

    IF rv_text CA lv_special.
      rv_text = |"{ replace( val = rv_text sub = `"` with = `""` occ = 0 ) }"|.
    ENDIF.

  ENDMETHOD.


  METHOD header_line.

    DATA(lo_struct) = CAST cl_abap_structdescr( cl_abap_typedescr=>describe_by_data( is_row ) ).

    LOOP AT lo_struct->components INTO DATA(ls_comp).
      DATA(lv_name) = quoted( iv_text      = CONV string( ls_comp-name )
                              iv_separator = iv_separator ).
      IF sy-tabix = 1.
        rv_line = lv_name.
      ELSE.
        rv_line = |{ rv_line }{ iv_separator }{ lv_name }|.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD row_line.

    FIELD-SYMBOLS <lv_value> TYPE any.

    DATA(lo_struct) = CAST cl_abap_structdescr( cl_abap_typedescr=>describe_by_data( is_row ) ).

    DO lines( lo_struct->components ) TIMES.

      ASSIGN COMPONENT sy-index OF STRUCTURE is_row TO <lv_value>.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.

      DATA(lv_text) = quoted( iv_text      = text_of( <lv_value> )
                              iv_separator = iv_separator ).

      IF sy-index = 1.
        rv_line = lv_text.
      ELSE.
        rv_line = |{ rv_line }{ iv_separator }{ lv_text }|.
      ENDIF.

    ENDDO.

  ENDMETHOD.

ENDCLASS.
