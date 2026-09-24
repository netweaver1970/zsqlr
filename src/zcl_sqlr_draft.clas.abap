" The editor as it was last left.
"
" Not a saved query and deliberately not one. A saved query is named,
" versioned, shared and deleted on purpose; this is the half-written thing
" that was on the screen when the phone rang. It belongs to one user, it
" has no name, and the next time that user opens the screen it is simply
" there.
"
" It is written on every trip through the selection screen rather than on
" leaving, because there is no reliable moment of leaving: Back and Cancel
" do not run AT SELECTION-SCREEN, so a draft kept until then would be the
" one thing lost by the one key most likely to be pressed.
CLASS zcl_sqlr_draft DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.

    CLASS-METHODS remember
      IMPORTING it_text TYPE rswsourcet.

    CLASS-METHODS recall
      RETURNING VALUE(rt_text) TYPE rswsourcet.

ENDCLASS.


CLASS zcl_sqlr_draft IMPLEMENTATION.

  METHOD remember.

    " Nothing on the screen is not the same as nothing to keep: an author
    " who clears the editor means it, and should not find yesterday's
    " statement back tomorrow.
    DELETE FROM zsqlr_last WHERE uname = @sy-uname.

    DATA lt_rows TYPE STANDARD TABLE OF zsqlr_last.
    DATA(lv_no)  = 0.

    LOOP AT it_text INTO DATA(lv_line).
      lv_no = lv_no + 1.
      APPEND VALUE #( mandt   = sy-mandt
                      uname   = sy-uname
                      line_no = lv_no
                      line    = lv_line ) TO lt_rows.
    ENDLOOP.

    IF lt_rows IS NOT INITIAL.
      INSERT zsqlr_last FROM TABLE @lt_rows.
    ENDIF.

    COMMIT WORK.

  ENDMETHOD.


  METHOD recall.

    SELECT line
      FROM zsqlr_last
      WHERE uname = @sy-uname
      ORDER BY line_no
      INTO TABLE @DATA(lt_lines).

    LOOP AT lt_lines INTO DATA(ls_line).
      APPEND INITIAL LINE TO rt_text ASSIGNING FIELD-SYMBOL(<lv_line>).
      <lv_line> = ls_line-line.
    ENDLOOP.

  ENDMETHOD.

ENDCLASS.
