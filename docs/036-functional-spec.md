# SQL reporting from SAP — functional specification (036)

A reporting tool inside SAP that lets a trusted analyst run a `SELECT` against a
named set of tables, save it, schedule it, and send the answer out as a grid, a
file or an e-mail — without giving anybody `DB02`, `SE16N` or a database logon.

The technical specification is [037](037-technical-spec.md). Section numbers
here are the ones the code's comments cite.

---

## 1. Why this exists

Sooner or later somebody has to ask SAP directly. Not "run the standard report
that summarises it" — ask the tables, join two of them, and see the rows. Two
systems disagree about a figure, an interface seems to drop a record, a
migration needs checking row by row. That is what a developer does in `SE16N`
and what a DBA does in `DB02`, and neither is something to hand to an analyst on
a production system: both read anything, and `DB02`'s SQL editor writes as
happily as it reads.

So: the power of a SQL prompt, with the blast radius of a report.

---

## 2. Who uses it

- **Report author** — writes, checks, runs and saves queries, and sends output
  to screen, file or e-mail. Analysts, operations, whoever is chasing a number.
- **Table list maintainer** — decides which tables each user may query. A small
  group: basis, or the application owner.
- **Administrator and auditor** — reads the run log and the log of changes to
  the table lists.

These are separate rights (§4.4). An author cannot widen their own reach:
adding a table to somebody's list is somebody else's job, and it is recorded.

---

## 3. What it does

### 3.1 Write and run a query

A screen with a proper editor — not a 255-character parameter — where the user
types or pastes SQL, and a **Check** that validates the statement without
running it and reports the columns it would return.

The editor depends on the front end, and the screen says which one a user got:

- **SAP GUI for Windows** — the ABAP source editor, with syntax highlighting.
  Written for, not yet tested.
- **SAP GUI for Java** — a plain text editor. Java draws the source editor
  without colours, so it would buy nothing there.
- **SAP GUI for HTML** (a browser) — a plain text editor. The browser front end
  cannot feed the source editor at all.

Running it produces rows. Nothing else: no write of any kind is allowed through
(§4).

**The screen reads top to bottom in the order the work happens.** Query name,
description, where the answer goes, the settings for that destination, the row
cap and cross-client switch, then the editor, which takes the rest of the
window. Fields belonging to a destination that is not selected are taken off
the screen: a recipient list is not a question anybody should have to answer
to produce a grid.

**Running is Run, or F8.** The standard Execute, which is also the only thing a
scheduled variant can trigger — so the screen a person uses and the job that
runs at three in the morning are the same program taking the same path. Check,
Save, Open and Admin sit beside Run on the application toolbar.

**The editor remembers.** Whatever was in it when the screen was last left comes
back next time, for that user. It is not a saved query and is not meant to
become one: a saved query is named, versioned and shared on purpose; this is the
half-written statement that was on the screen when the phone rang. It is kept on
every trip through the screen rather than on leaving it, because Back and
Cancel never reach the event that would have saved it.

### 3.2 Save, recall, retire

A query can be given a name and a description and kept. Saved queries are
**shared**: everyone with execute rights sees the same list, can run any of
them, and can change or retire any of them. That is a deliberate choice for a
small team — the alternative, private queries, means the same report gets
retyped by each person who needs it. Every save is a new version with who made
it, and the previous text is kept, so "who broke this query" is answerable.
Retiring a query takes it off the list and keeps its versions; saving the name
again brings it back.

A saved query is also what makes background running possible (§3.5): the
statement lives in a table, so it is not limited by what fits on a selection
screen.

### 3.3 See the answer

An **ALV grid**, in the dialog case. Sorting, filtering, totals, layouts and
Excel export are then SAP's own. Layouts are kept per saved query, because the
columns of one query are not the columns of another.

### 3.4 Send the answer somewhere

- **ALV grid** — dialog only.
- **A file on the user's PC** — CSV or XLSX; dialog only. In a browser the file
  arrives as a download, named after the query and the time.
- **A file on the application server** — CSV or XLSX; dialog or background.
- **E-mail** — CSV or XLSX attachment; dialog or background. A tickbox adds the
  statement, as typed, as a `.sql` attachment.

The format is chosen per run: **CSV** for the large extracts somebody will load
elsewhere, **XLSX** for the ones a person opens by hand. CSV streams, so a
result far larger than memory is written out a package at a time; XLSX is
assembled in memory and therefore capped (§6).

A local file and a grid both need a SAP GUI in front of them, which a
background job does not have. Both are refused when there is no front end,
naming the server file and e-mail as the two that do run unattended. The refusal
happens when the job runs, not when its variant is saved.

The CSV is written for the machine at the other end: UTF-8 with a byte-order
mark, CRLF line ends, a full stop for decimals, the minus sign in front, ISO
dates, and quoting only where needed. It does not guess: a date column the
database stores as characters — which is how SAP stores `DATS` on HANA — is
written as the eight digits it is. Deciding that any eight-digit value is a
date would turn document numbers into dates.

### 3.5 Run it in the background

A saved query, run by a job: a variant of the program naming the query, the
destination, the target (server path or recipients) and the format. Scheduling
is SAP's own (`SM36`), so a query can run nightly, monthly, or after a
dependency. Nothing new to learn. The job user's authorisations are what count,
not the scheduler's.

### 3.6 Know what happened

Every run is recorded in the application log (`SLG1`, object `ZSQLR`, subobject
`RUN`): who, when, which query, the statement as typed, how many rows,
which destination and target, whether it was current-client or cross-client,
and — on a refusal or failure — why. Refusals are logged too, and they are the
half that matters: a statement naming a payroll table is worth knowing about
*because* it was refused. The log is the answer to "who pulled that extract",
and transaction `ZSQLR_LOG` shows it without the editor.

---

## 4. The security model

The whole design rests on one asymmetry: **reading is useful and writing is
never needed here**. So writing is not restricted, it is absent.

### 4.1 Only `SELECT`

A statement must be a single `SELECT` (or a `WITH … SELECT`). Anything else is
refused before it reaches the database: no `INSERT`, `UPDATE`, `DELETE`,
`MERGE`, `UPSERT`, `TRUNCATE`, `DROP`, `CREATE`, `ALTER`, `GRANT`, `REVOKE`, no
procedure call, no `EXEC`, no anonymous block, no second statement after a
semicolon, no `SELECT … INTO`, no `FOR UPDATE`.

The refusal says which construct was found and where, because a person whose
query is refused needs to fix it, not guess.

### 4.2 Only tables on the user's list

Every table and view the statement reads must be on the list of **the person
running it**. Each user has a list of their own, so that several people can
use the tool with separately verified tables; an entry for the user `*`
applies to everybody. Entries are names or patterns (`ZSALES_*`), with an
optional note of why they are there. A statement naming anything else is
refused and says which name was not allowed and for whom.

A system has tens of thousands of tables. The list is not bureaucracy; it is
the difference between a reporting tool and a data-export tool for the whole
company, payroll included.

### 4.3 The current client, unless authorised otherwise

By default every client-dependent table is restricted to the caller's own
client, whether or not the author remembered `MANDT`.

A user holding the cross-client value of the authorisation (§4.4) may tick
*Cross-client* and run without that restriction, for system-wide analysis. The
statement then runs as typed, so a client-dependent table is read in every
client; include `MANDT` in the columns to tell the rows apart. The table list
applies exactly as before — reading every client widens which rows, never
which tables. The grid header starts *Every client*, a mail says it was run
across every client, and the log records the mode, because a cross-client
result that looks like a client result is how a figure gets counted once per
client.

### 4.4 One authorisation object, `Z_SQLR_RUN`

Three fields:

- **`ACTVT`** — `16` run a query, `03` see the table lists and the logs, `02`
  change the table lists.
- **`ZSQLROUT`** — where a result may go: `A` grid, `L` a file on the user's
  machine, `S` a file on the application server, `M` e-mail. One value per
  permitted channel.
- **`ZSQLRCLI`** — `C` this client, `X` every client.

One object rather than two: that writing reports and deciding what may be read
are different jobs is expressed as the gap between activity `16` and activity
`02`. The lists are maintained from inside the same transaction, by people who
already hold it, and a second object would be a second thing for somebody to
forget to assign.

The right that matters most is `ZSQLROUT`. Reading a table inside SAP and
mailing it out of SAP are not the same act, and this is the field that tells
them apart. It is checked on the screen *and* again in the class that does the
sending, so a future caller that is not the screen cannot skip it.

A user holding none of it does not reach the editor: the transaction says so and
closes.

### 4.5 The table list is the only table control

Ordinary table authorisations (`S_TABU_NAM` / `S_TABU_DIS`) are **not** checked.
A table on a user's list is readable by that user, whatever their role says
about that table elsewhere.

Stated rather than left implicit, because it moves weight onto two things:

- **An entry is a grant, not a filter.** The maintainer is deciding on somebody
  else's behalf, which is why maintenance sits behind its own activity and
  every change is recorded (§5). Users do not maintain their own lists; a list
  a user could extend at will would be no control. An entry of a single `*` as
  the table is refused outright — it would hand over every table in the
  database.
- **A table with a sensitive column does not belong on a list.** There is no
  field-level masking. The answer for a table like that is a database view that
  omits the column, put on the list in its place.

### 4.6 The residual risk, stated plainly

The statement runs as native SQL on the application's own database connection,
with the guard as the only thing standing between a statement and the database.
That is what `DB02` does too. It means:

**a defect in the guard is a defect in the security.** If a construct the guard
does not recognise can reach the database, the database will execute it with the
application's full rights.

- The guard is a whitelist — recognised and allowed, rather than scanned for
  badness — and is unit-tested against a corpus of evasions.
- Putting the database session into a read-only transaction would have been a
  second line. On HANA it is refused on this connection, and a write through
  the same connection is accepted. There is no second line.

The stronger design is a dedicated database user holding `SELECT` only, which
the tool connects through, so that a guard defect is harmless. That needs a DBA
once, and the code takes its connection in one place so it can be swapped
without touching anything else (037 §2.2). It is the recommendation for
production.

---

## 5. The table lists

An entry is: **a user** (or `*` for everybody), a table name or pattern, whether
it is active, an optional reason, and who changed it when. There is no
description: the audience is technical and the table name says what it is.

Patterns matter because dictionary tables come in families, and listing each by
hand means the list is out of date the first time somebody adds a table. A
pattern must end somewhere — `ZSALES_*`, not `*`.

Maintenance is one editable grid, reached from **Admin** in `ZSQLR` behind
activity `02` (activity `03` shows the same grid read-only): a row per user and
table, value help on both the user and the table name, one Save for the lot.
Rows are added on empty lines at the bottom and removed with a *Remove*
tickbox, and leaving with unsaved changes asks first. Removing a row deactivates
the entry rather than deleting it, and takes effect immediately; saved queries
that relied on it stop working and say why.

**Every change to the lists is recorded in the application log**, for audit:
who saved, when, and one line per grant added, removed or given a new reason.
The record is written together with the change or not at all — a change that
cannot be logged is refused. **Admin** shows it as *Who changed the table
lists*. Table logging is on as well, so a change made outside the tool still
shows in SAP's table change log (`SCU3`).

The lists start empty.

---

## 6. Limits, and what happens at them

As few as possible, each with a reason:

- **Statement length** — none. There is no 72- or 255-character ceiling
  anywhere; a stored line is folded at a space, never cut.
- **Rows** — *Max rows* on the screen, 500 by default, for any destination.
  A capped result **says so**: the grid's header reads that these are the first
  rows and there are more, because a grid that quietly holds the first 500 of
  40,000 is how somebody reports a wrong total. Set it to `0` for no limit.
- **Rows into CSV** — none beyond the cap you choose. Written a package at a
  time and never gathered, so the extract is bounded by the disk it is going
  to, not by the work process.
- **Rows into XLSX** — 1,048,575, the format's own limit less the header. The
  workbook is built in memory. Above it the tool caps rather than producing a
  file Excel calls corrupt, and names CSV as the way through.
- **E-mail size** — SAPoffice's own ceiling.

Every one of these, when hit, produces the three-part message the tool uses
everywhere: what it was doing, why it stopped, what to do about it.

---

## 7. Deliberately not built

- **No writes.** Not as an option, not for administrators, not behind a flag.
- **No DDL, no procedure calls, no cross-system queries.** A second system is a
  second security boundary.
- **No field-level masking.** The table list works at table granularity (§4.5).
- **No scheduler of its own.** `SM36` already exists.
- **No query results stored in SAP.** Output goes to a grid, a file or an
  e-mail; nothing is kept but the log of what ran.

---

## 8. How it is proven

1. A `SELECT` over an allowed table returns rows in a grid.
2. Every refused construct in §4.1 is refused with its own message — the list
   is a test case each (`ZCL_SQLR_GUARD`'s unit tests).
3. A table not on the user's list is refused and names itself and the user.
4. A client-dependent table returns only the current client's rows, with no
   `MANDT` in the statement; the same query run with *Cross-client* by somebody
   authorised for it returns the rows of every client, and is refused for
   somebody who is not.
5. A user without execute rights cannot start the transaction; a user without
   activity `02` cannot change the table lists.
6. A saved query runs unchanged in a background job, to a server file and to an
   e-mail.
7. The log shows all of the above afterwards, including the refusals.

---

## 9. Known gaps

- A background job that asks for a grid or a local file is refused when it
  runs, not when its variant is saved.
- There is no statement timeout of the tool's own; the database's and the work
  process's limits apply.
- There is no distinction between recipients inside and outside the company;
  anyone with `M` may mail any address.
- There is no retention rule for the log beyond SAP's own for the application
  log.
- Saved queries are not transportable; a query belongs to the client it was
  written in.
