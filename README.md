# ZSQLR — SQL reporting for SAP, behind a guard

ZSQLR lets a trusted analyst run a `SELECT` against a named set of tables,
save it, schedule it, and send the answer to a grid, a file or an e-mail —
without being given `DB02`, `SE16N` or a database logon.

It is the power of a SQL prompt with the reach of a report: native SQL, so
joins, `UNION`, window functions, `WITH` and subqueries all work, but only
`SELECT`, only against tables somebody has put on that user's list, and only
in the user's own client unless they are authorised for more.

## What it does

- **A real editor.** Paste a long statement, run it, save it. Lines are not
  limited to 72 or 255 characters; a stored line is folded at a space, never
  cut.
- **Check before Run.** *Check* runs the guard and has the database prepare
  the statement without executing it, and reports the columns it would
  return.
- **Only `SELECT`, recognised rather than filtered.** The guard parses the
  statement and refuses anything it does not recognise: DML, DDL, procedure
  calls, a second statement after a semicolon, `INTO`, `FOR UPDATE`, and so
  on. A refusal says what was found and where.
- **Per-user table lists.** Every table or view a statement reads must be on
  the list of the person running it. Entries can be patterns (`ZSALES_*`), and
  the user `*` means everybody.
- **Client-safe by default.** Every client-dependent table is restricted to
  the caller's client, whether or not the statement mentions `MANDT`. Ticking
  *Cross-client* reads every client instead, for those authorised for it; the
  grid, the mail and the log all say so.
- **Saved queries**, shared, versioned, with their history kept.
- **Four destinations:** an ALV grid, a file on the user's PC, a file on the
  application server, or an e-mail — as CSV or XLSX. CSV streams, so an
  extract larger than memory is fine. The e-mail can carry the statement as a
  `.sql` attachment.
- **Runs in the background.** The program is an ordinary report: save a
  variant naming a saved query and schedule it in `SM36`.
- **Everything is logged.** Every run and every refusal goes to the
  application log (`SLG1`, object `ZSQLR`, subobject `RUN`). Every change to
  the table lists goes there too (subobject `GRANT`), written in the same
  unit of work as the change, and the table itself has table logging on, so
  changes made outside the tool show in `SCU3`.
- **Works in SAP GUI for Java and SAP GUI for HTML** (the browser), both
  tested screen by screen, and is written for SAP GUI for Windows too, where it
  uses the syntax-highlighting source editor. Windows has not been tested yet;
  reports welcome. Java and the browser get a plain text editor, because that
  is what those front ends can draw.

## Read this before you install it on a production system

The statement runs as native SQL on the application server's own database
connection. **The guard is the only thing between a statement and the
database.** On HANA the default connection refuses `SET TRANSACTION READ ONLY`
and accepts writes, so there is no second line of defence at the database.
The guard is a whitelist parser with a large unit-test suite of evasions, but
a defect in it would be a defect in the security.

The stronger setup is a secondary database connection (`DBCON`) to a database
user that holds `SELECT` only, so that a parser gap becomes harmless. The
connection is taken in exactly one place — `ZCL_SQLR_EXEC=>CONNECTION` — so
switching to it is a one-line change plus a `DBCON` entry.

Two further things are deliberate and worth knowing:

- Ordinary table authorisations (`S_TABU_NAM`, `S_TABU_DIS`) are **not**
  checked. The table list is the table control. An entry on it is a grant,
  and the person maintaining it is deciding on somebody else's behalf.
- There is no field-level masking. A table with a sensitive column does not
  belong on a list; put a database view without that column there instead.

## Requirements

- SAP S/4HANA on HANA. Built and tested on ABAP Platform 2025 (SAP_BASIS 816).
  The code uses PCRE regular expressions, so ABAP 7.55 is the earliest release
  it could work on; releases before 816 are untested.
- [abapGit](https://abapgit.org), standalone or developer edition.
- For e-mail: a working SAPconnect (`SCOT`) node. Without one SAP accepts the
  mail and then reports it as not sent in `SOST`.

## Installing

1. Create a package for it, for example `ZSQLR` (`SE21`), with a transport
   layer if you want to move it on.
2. In abapGit, **New Online** with this repository's URL and your package —
   or download the repository as a zip and use **New Offline** and
   **Import zip**.
3. **Pull**. abapGit creates and activates 29 objects: two programs, eleven
   classes and an interface, four tables, two domains and data elements, two
   transactions, the authorisation object `Z_SQLR_RUN` with its object class
   and two fields, and the application log object `ZSQLR`.

## After installing

**Authorisations.** Create a role with:

- `S_TCODE` for `ZSQLR` (the editor) and `ZSQLR_LOG` (the run log).
- `Z_SQLR_RUN`:
  - `ACTVT`: `16` run a query, `03` see the table lists and the logs,
    `02` change the table lists.
  - `ZSQLROUT`: where results may go — `A` grid, `L` file on the PC,
    `S` file on the server, `M` e-mail. One value per permitted channel.
  - `ZSQLRCLI`: `C` this client only, `X` every client.
- `S_DATASET`, if server files are allowed; the kernel checks it on
  `OPEN DATASET`.

A user who holds `SAP_ALL` does **not** hold `Z_SQLR_RUN` until `SAP_ALL` is
regenerated, because the profile was built before the object existed. Every
check then correctly answers no. Grant the object in a role, or regenerate
`SAP_ALL`, and log on again: an open session keeps the authorisations it had
at logon.

**Table lists.** They start empty, so nobody can read anything yet. A user
with activity `02` opens `ZSQLR` → **Admin** → *Who may read which tables*,
types a user (or `*`) and a table or pattern on one of the empty lines, and
saves. A reason is optional and is kept. Ticking *Remove* and saving
deactivates a grant; nothing is deleted.

**Table logging.** `ZSQLR_GRANT` is delivered with *Log data changes* on.
It only records anything if profile parameter `rec/client` is `ALL` or names
your client (`RZ11`).

## Using it

Transaction `ZSQLR`. The application toolbar has **Run** (the same as F8),
**Check**, **Save**, **Open** and **Admin**.

- Type or paste a statement in the editor. It is kept for you between
  sessions until you replace it.
- Choose where the answer goes. The fields for that destination appear; the
  rest disappear.
- *Max rows* caps how many rows are fetched, for any destination (500 by
  default). A capped result says so. `0` means no limit, which is what a large
  CSV extract wants.
- *Query name* and **Save** keep the statement, shared with every user of the
  tool, as a new version each time. **Open**, or F4 on the name, brings one
  back.
- **Admin** also shows the run log, the log of changes to the table lists, and
  retires a saved query (its versions are kept).

Native SQL reads the physical tables, not CDS views and not the compatibility
views of S/4HANA: on S/4, goods movements are in `MATDOC`, not `MSEG`.

And it compares `NUMC` fields as the character strings HANA stores them as, not
as numbers. Two item numbers of different lengths never match — `'000010'`
(NUMC 6) is not `'00010'` (NUMC 5) — and neither does a short literal: a NUMC 10
field holds `'0000000010'`, not `'10'`. Pad the shorter side, e.g.
`n.docitm = LPAD(p.ebelp, 6, '0')`. Open SQL hides this; here it shows up as a
join that quietly returns nothing.

**Keep the values a query filters on at the top.** Native SQL has no parameters
here, but a one-row common table expression does the job, and a saved query
then reads like a form:

```sql
WITH v AS (
  SELECT '1000' AS plant,        -- which plant
         'ZOIL' AS material_type -- which material type
    FROM dummy
)
SELECT m.matnr, m.mtart, c.werks
  FROM v
  CROSS JOIN mara m
  JOIN marc c ON c.matnr = m.matnr AND c.werks = v.plant
 WHERE m.mtart = v.material_type
```

It reads `DUMMY`, HANA's one-row table, so put `DUMMY` on the list for everybody
(`*`) — it holds a single `X`. Join `v` with `CROSS JOIN`, not a comma: a comma
ranks below the joins after it, and `v` would not be visible in their `ON`
conditions.

**Comment freely.** Comments are removed before the statement goes to the
database — ADBC's placeholder parser would otherwise read an apostrophe in a
comment as an unclosed literal — and the run log keeps the statement as you
typed it, comments included.

## Documentation

- [docs/036-functional-spec.md](docs/036-functional-spec.md) — what the tool
  does and why, and its security model.
- [docs/037-technical-spec.md](docs/037-technical-spec.md) — how it is built,
  and the front-end and ABAP findings behind the less obvious choices.

Comments in the code refer to these as *spec 036* and *spec 037*.

## Licence

MIT — see [LICENSE](LICENSE).
