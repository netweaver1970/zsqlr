# SQL reporting from SAP — technical specification (037)

How the tool in [036](036-functional-spec.md) is built. Section numbers here
are the ones the code's comments cite.

Built on S/4HANA (ABAP Platform 2025, SAP_BASIS 816) on HANA. What it relies
on, all standard:

- **ADBC** (`CL_SQL_STATEMENT`, `CL_SQL_PREPARED_STATEMENT`) — native SQL, and a
  prepare that never executes.
- **`CL_GUI_SOURCEEDIT`** and **`CL_GUI_TEXTEDIT`** — the editor (5.1).
- **`CL_SALV_TABLE`** — the grid, and in memory the XLSX (§6). No abap2xlsx.
- **`CL_BCS`** — e-mail.
- **The application log** (`BAL_*`) — the run log and the audit log.

---

## 1. Object inventory

All in one package; abapGit brings them as a set.

- Transaction **`ZSQLR`** — write and run a query. Program `ZSQLR_RUN`.
- Transaction **`ZSQLR_LOG`** — read the run log. Program `ZSQLR_LOG_SHOW`.
- **`ZCL_SQLR_GUARD`** — the parser and the refusals. No database, no UI.
- **`ZCL_SQLR_CLIENT`** — rewrites a statement for one client.
- **`ZCL_SQLR_EXEC`** — ADBC: prepare, execute, fetch in packages.
- **`ZCL_SQLR_QUERY`** — saved queries: read, save, retire, versions.
- **`ZCL_SQLR_ALLOW`** — the table lists per user, the match, and the audited
  store.
- **`ZCL_SQLR_OUT`** — one entry point for local file, server file and e-mail.
- **`ZCL_SQLR_CSV`** — one row of unknown shape as one line of CSV.
- **`ZCL_SQLR_SINK_CSV`** and interface **`ZIF_SQLR_SINK`** — somewhere for rows
  to go that is not a grid.
- **`ZCL_SQLR_DRAFT`** — the editor as the user last left it.
- **`ZCL_SQLR_LOG`** — the run log, and the record of every change to the table
  lists.
- **`ZCL_SQLR_AUTH`** — every `AUTHORITY-CHECK` in the tool.
- Tables **`ZSQLR_QUERY`**, **`ZSQLR_QTEXT`**, **`ZSQLR_GRANT`**, **`ZSQLR_LAST`**
  (§9).
- Authorisation object **`Z_SQLR_RUN`**, its fields **`ZSQLROUT`** and
  **`ZSQLRCLI`** with their domains and data elements, and object class
  **`ZSQL`** (§8). Four characters is all an object class name takes.
- Application log object **`ZSQLR`**, subobjects **`RUN`** and **`GRANT`**.

There is no message class, lock object or settings table. Messages are built
in the code as three-part diagnoses (§10); saved queries are locked with the
generic table lock (5.4); the limits are on the screen or are constants.

---

## 2. Executing the statement

### 2.1 ADBC, and the shape of the problem

`CL_SQL_STATEMENT` runs native SQL and hands back a `CL_SQL_RESULT_SET`. The
awkward part of a generic tool is that ADBC wants somewhere to put the rows, and
the columns are not known until the statement is prepared.

1. Prepare — the database parses and resolves the statement without running it.
   This is also **Check** (5.2).
2. `CL_SQL_RESULT_SET=>GET_STRUCT_REF` turns the result's metadata into a
   structure — decimals, decfloats, timestamps and all. A type mapping of the
   tool's own would only be a second answer free to disagree with SAP's.
3. A table of that structure receives the rows, `next_package( )` at a time.

What the tool deliberately does not do is translate. The statement reaches HANA
as written, with HANA's semantics — including that a `NUMC` field is a character
string there. Joining a NUMC 6 item to a NUMC 5 item, or comparing a NUMC 10
field with `'10'`, matches nothing, silently; the author pads with `LPAD`. Open
SQL would have compared them as numbers, which is exactly the kind of help a
native-SQL tool cannot give without rewriting what the author wrote.

Nothing reads the whole result into memory unless the destination needs it
(§6). A CSV of forty million rows is a loop over packages and a `TRANSFER`; the
program's memory does not grow with the answer.

### 2.2 Read-only: asked for, and refused

The obvious second line of defence is a read-only transaction, so that the
database itself refuses a write that got past the guard. **On HANA it is not
available here.** On the default ADBC connection HANA answers:

> SET TRANSACTION is not allowed in this context

and a native `UPDATE` through that same connection is **accepted**. The
application's database user may write, and nothing at the database stops it.

So **the guard is the only thing between a statement and the data** (036 §4.6).
What would restore a second line:

- **A secondary connection (`DBCON`) to a database user holding `SELECT`
  only.** The only option that makes a guard defect harmless.
  `ZCL_SQLR_EXEC=>CONNECTION` is the single place the connection is taken, so
  this is a change of one line plus a `DBCON` entry.
- Untested: whether a secondary connection accepts `SET TRANSACTION READ ONLY`
  where the default one does not.

The tool never issues `COMMIT WORK` around a statement, and the ADBC connection
is rolled back at the end of every run. That is housekeeping, not protection.

---

## 3. The guard

This is the security boundary. It is one class, it has no dependencies, and it
is the most heavily tested thing in the tool.

### 3.1 Whitelist, not blacklist

The parser does not scan for dangerous words. It recognises the grammar of the
statements it permits and refuses everything it does not recognise. A construct
nobody thought of is refused by default rather than allowed by default — which
is the only way a guard survives contact with a language as large as HANA SQL.

### 3.2 The passes, in order

**1. Normalise.** Strip comments (`--` to end of line, `/* … */`, nested), and
replace string literals with a placeholder so their contents can never be read
as syntax. A quoted identifier (`"MY TABLE"`) is kept, marked as an identifier.
An unterminated literal or comment is refused.

**2. One statement.** A semicolon outside a literal ends the statement; anything
after it is refused. That is `SELECT … ; DROP …` in one rule.

**3. First keyword.** `SELECT`, or `WITH` that resolves to a `SELECT`. Nothing
else starts a statement.

**4. Forbidden constructs.** Belt and braces rather than the mechanism: `INTO`,
`FOR UPDATE`, `LOCK`, any DML or DDL keyword, `CALL`, `EXEC`, `DO`, `BEGIN`,
`IMPORT`, `EXPORT`, session and system `SET`, and the HANA procedural
constructs.

**5. Collect the sources.** Every identifier in a `FROM` or `JOIN` position, at
every nesting depth, including inside `WITH` clauses. A `WITH` name is a local
alias and is *not* checked against the table list — it is not a table — but
anything it selects from is.

**6. Check each source** against the active rows of `ZSQLR_GRANT` for the
running user and for `*`, with pattern matching (5.5). A schema-qualified name
(`SAPHANADB.MARA`) is refused outright rather than stripped: the lists name
tables, and letting a schema through is how a system table gets read.

**7. Hand the source list on** to the client rewrite (§4).

### 3.3 What the guard refuses to be clever about

If the parser cannot confidently identify the sources of a statement — an exotic
join syntax, a table function, a construct it does not model — it refuses the
statement and names the fragment it could not read. A guard that guesses is not
a guard.

### 3.4 Tests

ABAP Unit, and the tests are the specification: every construct in 3.2/4 is its
own refusal; evasions — a keyword hidden in a comment, a semicolon inside a
literal, a comment inside a keyword (`SEL/**/ECT`), mixed case, nested
comments, a `UNION` onto a forbidden source, a subquery three levels down naming
a table nobody allowed, a `WITH` that shadows a real table name; and the allowed
cases, which must not be refused — joins, `UNION ALL`, window functions, `CASE`,
aggregates, `WITH`, scalar subqueries.

---

## 4. Client handling

### 4.1 Which tables are client-dependent

`MANDT` (or `MANDANT`) as the first key field, read from `DD03L`. Anything else
is cross-client by nature and is left alone.

### 4.2 The rewrite

Rather than editing the `WHERE` clause — which means understanding it, and
getting `OR` precedence right every time — each client-dependent source is
replaced by a derived table:

```
FROM mara AS m    →   FROM (SELECT * FROM mara WHERE mandt = '100') AS m
JOIN marc ON …    →   JOIN (SELECT * FROM marc WHERE mandt = '100') AS marc ON …
```

The restriction travels with the table wherever it is used, whatever the outer
`WHERE` does, including in subqueries and `UNION` branches. An unaliased source
is given its own name back as the alias, so every column reference still
resolves. The client is `sy-mandt`. The log keeps the rewritten statement,
because that is what ran.

### 4.3 Cross-client

With *Cross-client* ticked, the authorisation `ZSQLRCLI` = `X` is checked and
the rewrite is skipped: the statement runs as typed. The guard and the table
list have already run by then, so reading every client widens which rows,
never which tables. Somebody without the authorisation is refused before
anything reaches the database.

It is said everywhere the answer goes: the grid header starts *Every client*,
the mail body says the run was across every client rather than naming one, and
the log records `Read every client` with the statement as sent — unrewritten.
`ZCL_SQLR_OUT=>DELIVER` takes an every-client flag and repeats the
authorisation check itself before delivering a file or a mail, because it
receives the statement already built and cannot tell a rewritten one from one
that was not.

---

## 5. The dialog program

The whole program is source code: a selection screen, a docking container and
controls, no screen painter. That is what lets abapGit carry it as a program and
its texts, and nothing else.

### 5.1 The editor, and three front ends

**SAP GUI for Windows** gets `CL_GUI_SOURCEEDIT` in a docking container at the
bottom of the selection screen. It highlights.

**SAP GUI for Java and SAP GUI for HTML** get `CL_GUI_TEXTEDIT` in the same
docking container, fed with `set_textstream` and read with `get_textstream`.
Java draws the source editor without colours, so it bought nothing there; and
the browser cannot feed it (below).

**The front end is predicted, never tested for.** `CREATE OBJECT` on a control
does not talk to the front end: it queues, and answers `sy-subrc` 0 whatever is
on the other end. A refusal arrives at the PBO flush instead, as `CNDP 006` out
of `SAPLOLEA`, a type X message nothing can catch, and the transaction dies
before drawing its screen. So a `sy-subrc` check after `CREATE OBJECT` proves
nothing, and a fallback behind one is never reached. The front end is read from
`CL_GUI_OBJECT`: Windows reports ActiveX and not ITS, Java reports JavaBeans,
and SAP GUI for HTML reports ActiveX **and** ITS (`www_active`). The code asks
it as "neither Java nor ITS", which gives the same three answers and is what
abaplint's copy of `CL_GUI_OBJECT` can check.

**In a browser, the text moves as a stream, not as a table.**
`set_text_as_r3table` and `get_text_as_r3table` are not implemented by SAP GUI
for HTML, and that one call is what kills a browser editor: the container
renders, the control is created without complaint, and the flush dies.
`set_textstream` / `get_textstream` work, and carry no per-line width, which
matters more than the front end does (5.1.1). Timing does not help: sending the
table a round trip after the control was created dumps the same way. The
docking container itself is fine in a browser.

**What sits above the editor.** Every line up there is a line of SQL out of
sight, so the selection screen is four lines when the answer goes to the grid:
*Query name*; *Query description*, on its own line so it can show sixty
characters; the four destinations; row cap, highlighting language and
*Cross-client*. A file adds two lines, mail three. Everything a destination does
not use is taken off the screen, not greyed. There are no frames: SAP GUI for
HTML draws each framed block with a title bar and padding several lines tall.

**The editor takes a share of the window**, not a height in pixels, because the
window is not always the same size and the lines above are. A docking container
has `SET_EXTENSION` but no `SET_RATIO`, so a different share means a new
container; nothing is lost when it is rebuilt, because `remember( )` has read the
editor into the draft in the same round trip. The shares, measured at a window
about 680 pixels high:

- Browser: 71 under the grid, 60 under a file, 55 under mail.
- SAP GUI for Windows and Java: 80, 73 and 69. They lay lines out far tighter.

**A browser measures the first container differently from every later one.**
The share of the first container in a session is taken of the whole page; every
container built after it — after a destination change, after coming back from a
run — is a share of the area under the toolbar, some 90 pixels less. So the
first container is scaled to 85 per cent of its share. A taller window leaves a
band above the editor; none of these shares overlaps the fields at the size they
were measured.

**A docking container does not survive list processing.** After a run the
reference is still bound and the control behind it is gone, so the editor is
rebuilt from the draft when the screen comes back.

**Reading the editor needs a flush.** `get_text` queues a request and leaves the
table as it was until `CL_GUI_CFW=>FLUSH` runs; without it, Save stores the
previous statement under the new name. Every read flushes, and an empty read
never overwrites a draft that has something in it.

Selection screen 1000 is less forgiving than it looks, and each of these cost a
failed activation whose only message was *"Error when generating selection
screen 1000"* (`RSDBGENA` names the class of error, not the line):

- An **integer** parameter on a line takes more columns than its digits
  suggest.
- Nothing on a line may overlap the next thing on it, or run past about
  column 75.
- A listbox declared `TYPE c LENGTH 4` inline cannot also carry `USER-COMMAND`;
  it needs a named type.
- A field inside `BEGIN OF LINE` loses its selection text and needs a
  `COMMENT … FOR FIELD`.
- A field without `LOWER CASE` upper-cases what is typed, on every round trip —
  a description is then saved in capitals.

### 5.1.1 Why a stored line is 255 characters and a written one is not

A stored line is `CHAR 255`, because that is what `RSWSOURCET` and the text
table hold. A written line can be longer, and must not be cut.

`CL_GUI_SOURCEEDIT`'s `max_number_chars` is passed on as its
**WordWrapPosition**: it wraps, it cuts nothing, and the control is built for two
widths, 72 and 255. Set to 1024, SAP GUI for Java draws the control empty; it
stays at 255.

Every read goes through one funnel: the source editor into a 1024-wide table
(`get_text` types its table generically, so a wider line type is allowed), the
plain editor as a stream, which has no width at all. `tidy( )` then drops
trailing padding and folds anything longer than a stored line **at the last
space that fits**, so no identifier is split; a single token over 255 is broken
on the boundary, and the remainder goes to the next line. Nothing is lost at any
width.

### 5.2 Check

Guard, then rewrite, then prepare — in that order. If prepare ran first, a user
could learn whether a table exists from the database's error message, which is a
small oracle but a free one. A clean check reports the columns the query will
return.

### 5.3 Run

Guard → rewrite → prepare → execute → fetch. The grid is `CL_SALV_TABLE` over the
dynamic table, with a layout key per saved query — without a layout key SALV
hides the layout functions, and one key for every query would offer one query's
columns to another. The row cap truncates and says so in the header.

### 5.4 Saving

Name, description, the text, and an incrementing version. The previous text is
kept in `ZSQLR_QTEXT` rather than overwritten. Two people saving the same query
are kept apart with `ENQUEUE_E_TABLE` on the query's key rather than a lock
object of the tool's own. The name is strict — letters, digits and underscore —
because it is how a background variant asks for the statement.

### 5.5 The table lists

**The rule.** A row of `ZSQLR_GRANT` says one user may read one table or
pattern. The user `*` means everybody. A user reads the union of their own rows
and the `*` rows; somebody else's row allows them nothing. A refusal names the
user — *"KNA1 is not on the list of tables ANALYST may read"* — because with
lists per user, "the list" no longer says which one.

**The screen.** **Admin** → *Who may read which tables* opens an editable
full-screen grid (`REUSE_ALV_GRID_DISPLAY_LVC`): user, table or pattern, an
optional reason, and who changed the row and when. F4 on the user lists users
(search help `USER_COMP`) and on the table searches the repository
(`DD_DBTB_16`), both bound in the table definition — the data elements `XUBNAME`
and `TABNAME` carry no search help of their own. Without activity 02 the grid is
read-only and says why.

**Adding and removing are done in the data, not with row buttons.** The
full-screen ALV of this release has none to offer: with the unified toolbar the
grid's toolbar moves into the menu bar and the group holding insert, append and
delete row is mapped to nothing on the way; a popup grid has no toolbar at all.
So the grid carries five empty lines to type new grants into and a *Remove*
tickbox on every row, and it works the same in every front end. Save hands the
grid to `ZCL_SQLR_ALLOW=>STORE` with the ticked rows left out, and whatever is
not handed over is deactivated. Empty lines are skipped.

Three things the grid needed:

- The cell the cursor is still in has not reached the program when Save is
  pressed — in a browser it travels with the next round trip. Every user
  command asks the grid for pending input first (`GET_GLOBALS_FROM_SLVC_FULLSCR`,
  then `CHECK_CHANGED_DATA`).
- The reason is a built-in `CHAR 120` with no lower-case flag, so the grid
  upper-cased it. `LOWERCASE` in the field catalogue is overridden by a
  dictionary reference, so that column is described without one.
- Back, Exit and Cancel are registered as exit events *before* the grid
  closes; the handler compares the grid with the table, asks *Leave* or *Stay*
  when they differ, and clears the exit flag to stay.

**Every change is in the application log.** `STORE` checks every row before
writing any — blank rows skipped, duplicates refused, the user must exist in
this client or be `*`, the entry must be a valid name or pattern — then works out
what was added, removed or given a new reason. It writes those rows and a log
under object `ZSQLR`, subobject `GRANT`, in the **same unit of work**: a headline
(*"ADMIN changed the table lists: 1 added, 0 removed, 0 with a new reason"*) and
one line per change. If the log cannot be written, the change is rolled back and
refused, so there is never a change without its record. Nothing is deleted: a
removed grant is a row with `ACTIVE` cleared, and adding it again sets the flag.

What the application log does not see is a change made outside the tool — SE16N,
a program. `ZSQLR_GRANT` has no maintenance view and its data maintenance is
restricted, which narrows that to people who can already write to any table, and
**table logging** covers the rest: *Log data changes* is on in the table's
technical settings, so every insert, update and delete lands in `DBTABLOG`
whoever makes it, and `SCU3` shows it — provided profile parameter
`rec/client` is `ALL` or names the client. The two records overlap on purpose:
the application log says what a change meant, `SCU3` proves the row changed.

---

## 6. Output

One entry point, `ZCL_SQLR_OUT=>DELIVER`, takes the statement, the destination,
the format and the target, and the screen decides nothing else. A scheduled
variant producing the same extract produces the same bytes, because it goes
through the same method.

- `ZIF_SQLR_SINK` — `open` / `write` / `close` / `failure`.
- `ZCL_SQLR_EXEC=>STREAM` — fetches package by package and hands each to a sink,
  keeping none. `RUN` builds the complete answer, which a grid needs and a file
  must not.
- `ZCL_SQLR_CSV` — one row of unknown shape as one line of CSV. Pure, and
  unit-tested.
- `ZCL_SQLR_SINK_CSV` — the bytes are either appended to an xstring or
  transferred to an open dataset; that one line is the only difference.

**CSV.** Binary mode, not text: text mode takes the line ending and code page
from the application server's platform, so the same query on another host would
produce a different file. Here both are chosen — CRLF, UTF-8, with a byte-order
mark, without which a spreadsheet guesses the code page. A full stop for
decimals, the minus sign in front, ISO dates, quoting only where needed with an
internal quote doubled. ABAP hands a negative packed number over with the sign
at the **end** (`1234.56-`) and a positive one with a blank where the sign would
be; both are undone. A `DATS` column is stored on HANA as characters, arrives as
eight digits, and is written as eight digits; only a column the database types
as a date becomes `YYYY-MM-DD`.

**Server files.** `OPEN DATASET` is checked by the kernel against `S_DATASET`,
the standard control. What is checked here is `..`, so the path cannot step up
the tree.

**XLSX.** `CL_SALV_TABLE=>TO_XML( if_salv_bs_xml=>c_type_xlsx )` on a SALV built
in memory and never displayed — the same class as the grid, so the workbook and
the screen carry the same column headings. Held in memory, hence the cap.

**E-mail.** `CL_BCS`, the attachment named after the query and the time, sent
and committed — without the `COMMIT WORK` the send request is rolled back at the
end of the dialog step and nothing goes. The body carries the row count and who
ran it, in which client of which system. The statement travels as a `.sql`
attachment only when *Attach the SQL statement* is ticked, UTF-8 with Windows
line ends, and it is the statement **as typed**, not the rewritten one: a mail is
for a person. "Sent" means SAP accepted the mail; whether it left is SAPconnect's
business, and `SOST` shows it.

**A local file in a browser** has no meaningful path: SAP GUI for HTML hands the
file to the browser as a download, and the browser decides where it lands using
only the name. There an empty file field is not refused; the name is made from
the query and the time. On a desktop the path decides where the file goes, and an
empty one is refused. In both, the extension follows the format.

---

## 7. The background runner

There is no separate batch program. `ZSQLR_RUN` **is** the background runner:
running it is F8, so it goes through `START-OF-SELECTION` like any report, and a
variant of it is a job step. The variant carries the query **name**; the
statement comes from the store, which is how the selection screen's limits are
avoided entirely.

With no front end the program creates no control (a docking container in a job
is how a scheduled report dumps), refuses the grid and the local file, and writes
its three-part messages to the job log as three lines rather than into a popup
nobody is there to acknowledge. On success it writes the row and byte counts to
the job log. The job user's authorisations are what count.

---

## 8. Authorisation object

**`Z_SQLR_RUN`**, in object class `ZSQL`:

- `ACTVT` — `16` run a query, `03` see the table lists and the logs, `02` change
  the table lists.
- `ZSQLROUT` — `A` grid, `L` local file, `S` server file, `M` e-mail; one value
  per permitted channel.
- `ZSQLRCLI` — `C` this client, `X` every client (4.3).

Checked in the transaction *and* again in the service classes, so a caller that
is not the screen cannot skip it — `ZCL_SQLR_OUT=>DELIVER` repeats the channel
check before it reads a row. The checks fail closed. Every field of the object is
named in each `AUTHORITY-CHECK`, with `DUMMY` where it does not matter, because
leaving one out fails the check rather than ignoring it.

`S_TABU_NAM` is **not** checked (036 §4.5): the table lists are the table control.

**The one that will catch anybody testing this.** A brand-new authorisation
object is not in `SAP_ALL` until `SAP_ALL` is regenerated. A developer holding
`SAP_ALL` gets no on every check of `Z_SQLR_RUN` — correctly, because the profile
was generated before the object existed. Regenerate it, or better, grant the
object in a role. And a session already open keeps the authorisations it had at
logon: log on again.

---

## 9. Tables

- **`ZSQLR_QUERY`** — client, query name (key), description, active, created
  by/at, changed by/at, current version.
- **`ZSQLR_QTEXT`** — client, query name, version, line number (key), text line.
  Held as lines rather than one string, which keeps one version comparable with
  the next. A stored line is `CHAR 255`; a longer one is folded at a space
  (5.1.1).
- **`ZSQLR_GRANT`** — client, user, table or pattern (key), active, reason,
  changed by, changed at. Delivery class `A`: the lists name users, and users are
  not the same in test and production, so a list is maintained where it applies
  rather than transported. Table logging on; value helps on user and table.
- **`ZSQLR_LAST`** — client, user, line number (key), text line. The statement
  that was in the editor when the screen was last left, for that user. Replaced
  wholesale on every trip through the screen, so an editor cleared on purpose
  stays cleared.

---

## 10. Errors

Every refusal and every failure is a three-part message: **what the tool was
doing, why it stopped, what to do about it.** For example:

> **Checking the statement.** `KNA1` is not on the list of tables ANALYST may
> read. Admin → *Who may read which tables* shows the lists and who last
> changed them; adding to them needs `Z_SQLR_RUN` activity 02.

> **Checking the statement.** A second statement was found after the semicolon
> at position 412. This tool runs one `SELECT` at a time.

In dialog they are a popup; in a job, three lines of job log.

---

## 11. What abapGit carries

Everything the tool needs is an object abapGit serialises, so a pull is the
whole installation: the programs with their selection texts, the classes and
their unit tests, the tables with their technical settings (including *Log data
changes*) and search-help bindings, the domains and data elements, the
transactions, the authorisation object with its fields and object class, and the
application log object with both subobjects.

What abapGit cannot carry is configuration of the target system: roles, the
table lists themselves, `rec/client`, SAPconnect, and a `DBCON` entry if you
follow 2.2. The README lists them.

---

## 12. Known gaps

- In the table-list grid in a browser, the cell still being typed in when Save
  is pressed is usually picked up (5.5), but once, after three new rows typed
  in one go, its value was lost. Click out of the last cell before Save when it
  matters.
- A background job asking for a grid or a local file is refused at run time, not
  when its variant is saved.
- The highlighting language: `CL_GUI_SOURCEEDIT` highlights ABAP; whether a
  given SAP GUI for Windows accepts `SQL` as a source type is untested. ABAP
  highlighting still reads, since `SELECT`, `FROM`, `WHERE`, `JOIN` are ABAP
  keywords too; SQL's `--` comments are not ABAP's.
- **SAP GUI for Windows is untested.** Its path — the source editor, fed as a
  table, and its own editor shares — is written but has never been run. Java
  and the browser have been tested screen by screen.
