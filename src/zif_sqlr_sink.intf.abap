INTERFACE zif_sqlr_sink PUBLIC.

* Somewhere for rows to go that is not a grid.
*
* An ALV holds every row in memory on the application server, and that is
* the one cap this tool cannot argue with. A file has no such need: the
* rows can be written as they arrive and forgotten. That is the whole
* reason this interface exists -- it lets ZCL_SQLR_EXEC hand over one
* package at a time instead of building the complete answer first, so a
* hundred-million-row extract costs one package of memory, not a hundred
* million rows of it.
*
* Spec 036 section 6: "as little limits as possible on output dataset
* size". This is where that promise is kept.

  "! Called once, before the first row, with an empty row of the query's
  "! own shape. Column names come from it.
  METHODS open
    IMPORTING ir_row TYPE REF TO data.

  "! Called once per package. The table belongs to the caller and is
  "! refilled after this returns, so anything worth keeping is kept now.
  METHODS write
    IMPORTING ir_package TYPE REF TO data.

  "! Called once, after the last package -- and also after a failure, so
  "! that a half-written file is still closed.
  METHODS close.

  "! Empty for as long as nothing has gone wrong. Checked between
  "! packages, so a disk that fills up stops the fetch rather than being
  "! discovered at the end of it.
  METHODS failure
    RETURNING VALUE(rs_diag) TYPE zcl_sqlr_guard=>ty_diag.

ENDINTERFACE.
