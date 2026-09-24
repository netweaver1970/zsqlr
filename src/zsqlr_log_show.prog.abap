REPORT zsqlr_log_show.

*&---------------------------------------------------------------------*
*& Who ran what, and where it went. Transaction ZSQLR_LOG.
*&
*& Barely a program, and that is the point. The log is SAP's own
*& application log -- object ZSQLR, subobject RUN -- so this is SLG1
*& arriving already filtered on this tool, rather than a viewer of our
*& own over a table of our own.
*&
*& It exists as a transaction, unlike the table list, because the people
*& who read it are auditors and administrators rather than query authors,
*& and asking them to open the SQL editor to reach the log would be
*& asking them to hold a right they should not need. The same display is
*& on a button inside ZSQLR for the people who are already there.
*&
*& Anybody who would rather use SLG1 itself can: object ZSQLR.
*&---------------------------------------------------------------------*

PARAMETERS p_from TYPE d.
PARAMETERS p_user TYPE xubname.


INITIALIZATION.
  " A month back. Long enough to answer "who pulled that extract" and
  " short enough that the first screen is not the whole log.
  p_from = sy-datum - 30.


START-OF-SELECTION.

  " Reading the log is the same right as seeing the table list: both are
  " read-only views of the tool's own records rather than of anybody's
  " data.
  DATA(gs_may) = zcl_sqlr_auth=>may_read_log( ).
  IF gs_may-ok = abap_false.
    CALL FUNCTION 'POPUP_TO_INFORM'
      EXPORTING
        titel = 'SQL reporting'
        txt1  = CONV char80( gs_may-diag-what )
        txt2  = CONV char80( gs_may-diag-why )
        txt3  = CONV char80( gs_may-diag-fix ).
    RETURN.
  ENDIF.

  zcl_sqlr_log=>show( iv_from = p_from
                      iv_user = p_user ).
