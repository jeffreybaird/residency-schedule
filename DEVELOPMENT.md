# Development Setup

## Prerequisites

Install the following before starting:

| Tool | Version | Install |
|---|---|---|
| Elixir | ~> 1.19 (CI: 1.19.5) | [asdf](https://asdf-vm.com) or [mise](https://mise.jdx.dev) recommended |
| Erlang/OTP | CI: 28.5.0.7; OTP 29 requires 29.1.1+ | Install a patched version compatible with Elixir |
| PostgreSQL | 14+ | `brew install postgresql` on macOS |
| Node | Optional for JavaScript tests | Asset builds download esbuild/Tailwind through Mix |
| Ruby | 3.3 | Deployment-tool tests; Minitest required |
| Python | 3 | Synthetic demo validation |

### Install Elixir via mise (recommended)

```bash
mise use erlang@28.5.0.7 elixir@1.19.5-otp-28
```

### Install Elixir via asdf

```bash
asdf plugin add elixir
asdf plugin add erlang
asdf install erlang 28.5.0.7
asdf install elixir 1.19.5-otp-28
asdf set erlang 28.5.0.7
asdf set elixir 1.19.5-otp-28
```

---

## First-time setup

### 1. Clone and install dependencies

```bash
git clone git@github.com:<your-org>/residency-schedule.git
cd residency-schedule
mix deps.get
```

### 2. Create and migrate the database

Make sure PostgreSQL is running. `config/dev.exs` and `config/test.exs` default
to `postgres` / `postgres` on `localhost`. The databases are
`residency_schedule_dev` and `residency_schedule_test` (with an optional
`MIX_TEST_PARTITION` suffix). Configure these files for your local credentials;
the local role must be able to create the development and test databases. Then:

```bash
mix ecto.setup
```

This runs `ecto.create`, `ecto.migrate`, and `priv/repo/seeds.exs` in sequence.
The seed script currently contains no records; it creates neither an admin nor
a schedule. `mix setup` combines dependency installation, database setup, asset
tool installation, and the initial asset build.

If you only want to create and migrate (no seeds):

```bash
mix ecto.create
mix ecto.migrate
```

### 3. Install JavaScript and CSS build tools

The first time you run the dev server, Tailwind and esbuild binaries are downloaded automatically. You can also trigger this manually:

```bash
mix assets.setup
```

### 4. Sign in and bootstrap a local administrator

The browser uses individual accounts, not a shared access password.

1. Start the server and open `/login`.
2. Enter your email and request a magic link. Without `RESEND_API_KEY`, development
   mail appears at [http://localhost:4000/dev/mailbox](http://localhost:4000/dev/mailbox).
3. After the email has created the account, promote it in another terminal:

   ```bash
   mix run -e 'ResidencySchedule.Release.promote_admin("you@example.test")'
   ```

4. Open the magic link and confirm sign-in. You can then set an account password
   and use `/admin/upload`. Promotion also approves the account.

URMC addresses register as approved residents; other new accounts need admin
approval. Keep real email addresses, rosters, and credentials out of Git.
The legacy `:access_password` configuration does not authenticate browser users.

### Optional integrations

Development uses the local Swoosh mailbox by default. Setting `RESEND_API_KEY`
switches it to real email delivery. Setting `ANTHROPIC_API_KEY` enables the chat
assistant; neither key is required for ordinary development. Test configuration
uses the fake chat provider and the Swoosh test adapter.

---

## Running the development server

```bash
mix phx.server
```

Visit [http://localhost:4000](http://localhost:4000) and sign in with your account.
The home page is the calendar; the rotation grid is at `/schedule`.

To run in interactive mode (gives you an IEx shell):

```bash
iex -S mix phx.server
```

---

## Running tests

```bash
mix test
```

The test alias automatically creates and migrates the test database before running. Tests use a DB sandbox — each test gets a clean slate. Do not share state between tests.

Run a single file:

```bash
mix test test/residency_schedule/importer/csv_parser_test.exs
```

Run a test at a specific source line:

```bash
mix test test/residency_schedule/importer/csv_parser_test.exs:7
```

`--only` filters ExUnit tags, not filenames; use a file path for integration suites.

---

## Precommit check

Run the precommit alias (format with corrections, compile with warnings-as-errors,
remove unused lock entries, then tests):

```bash
mix precommit
```

This should pass cleanly before every push. It can modify formatting and
`mix.lock`; review the diff. For read-only verification use:

```bash
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
mix deps.unlock --check-unused
mix credo --strict
```

PR CI runs compilation, ExUnit, the three Ruby suites below, and Python demo
validation. The deploy workflow runs ExUnit, release-artifact tests, and Python
validation before building. Neither workflow currently runs the complete
precommit alias, strict Credo, or the JavaScript suite.

```bash
ruby test/deploy/release_artifacts_test.rb
ruby test/deploy/database_recovery_test.rb
ruby test/deploy/production_backup_test.rb
python3 -m unittest discover -s test -p '*_test.py'
node --test test/assets/*.test.js
```

The palette test requires built CSS (`mix assets.build`) and Chrome. On Linux,
set `CHROME_BIN` to the installed Chrome/Chromium executable; its default path
is the macOS Google Chrome application. The other JavaScript files run in Node.

The database recovery/backup suites have platform and tool prerequisites; see
[database recovery](.docs/database-recovery-runbook.md) and
[production backups](.docs/production-backup-runbook.md).
For a dependency advisory check with current Hex data, run `mix hex.audit`.

---

## Uploading a schedule CSV

After starting the server:

1. Navigate to [http://localhost:4000/admin/upload](http://localhost:4000/admin/upload).
2. Select **Replace year** for a complete schedule, or **Update dates** for a partial schedule such as winter float assignments.
3. For **Update dates**, select the existing academic year explicitly. January 2027 assignments belong to 2026–2027.
4. Select the CSV and click **Import Schedule**. Review the year, dates, warnings, and resident matches, then confirm.

**Replace year** derives the year from the file and replaces every schedule resident and rotation in that year. It is blocked when saved QGenda activities depend on that roster. Whole-year replacement can also remove coverage requests and overrides; prefer date updates for partial corrections. **Update dates** keeps existing resident identities and replaces only the supplied residents' recognized assignments on their source date ranges. A longer existing rotation is split to preserve dates before and after the update. Residents absent from the file are preserved.

**Admin → Edit Schedule** uses each saved assignment's actual dates. Overlapping assignments appear separately and can be edited individually. Add, edit, and delete actions remain staged until **Save**; **Undo** reverses staged actions and **Cancel** discards them. Saving applies only explicit assignment changes, preserving untouched records and resident identities. A save with no changes preserves all records. If the schedule has changed since loading, reload before editing again. Assignments referenced by a coverage request or override cannot be changed or deleted; resolve their coverage history first. The schedule generator remains separate from this editor.

In date updates, `OFF` explicitly removes assignments on that date range. Blank, omitted, and unrecognized cells preserve existing assignments; review the warnings, since unresolved labels leave `FLOAT` placeholders in place. Use literal dates for Highland night float in update mode. Highland weekend nights retain the Saturday-only rule; an uploaded Saturday–Sunday HWN cell clears the stale Sunday assignment. Duplicate resident positions, overlapping or invalid date columns, and dates outside the selected July–June year are rejected before saving.

Date updates cannot alter a rotation referenced by a coverage request or override, even if that coverage is on a different part of the rotation. The update is rejected atomically to preserve coverage history. The existing **Replace year** operation remains a whole-year replacement.

### Expected CSV format

```
Row 0: "",  "Dates", "2026-07-06", "2026-07-13", ...   ← start dates
Row 1: "",  "",      "2026-07-12", "2026-07-19", ...   ← end dates
Row 2: event annotation row (Retreat, CREOGS, etc.)    ← skipped
Row 3+: resident rows: "R4-1", "Briar", "ONC", "HWD", ...
```

Only rows where column A matches `R[1-4]-\d+` are imported. All other rows are skipped.

### QGenda daily assignments

The separate QGenda form on `/admin/upload` accepts a **Calendar By Staff**
`.xlsx` export for an existing academic year. Preview staff matches, tasks,
notes, and date coverage, then confirm saving matched activities. If names cannot
be matched, supply a reviewed CSV crosswalk in that form; ignored local files
are not deployed automatically.

Activities supplement rotations without renaming people or replacing the base
schedule. Repeated imports deduplicate identical activities and add new ones;
missing tasks are not deleted. A changed label can coexist with the old activity.
Dates must fall between June 1 of the selected start year and June 30 of the
following year. An empty result does not imply time off or availability.

See [QGenda preview and crosswalks](.docs/qgenda-preview.md),
[daily assignments](.docs/qgenda-activities.md), and
[activity search through MCP/chat](.docs/activity-search-mcp.md).

### Verifying imports

Review preview warnings and saved assignments in `/schedule`, `/calendar`, and
the resident view. Use synthetic fixtures such as `test/fixtures/sample.csv` for
local checks. There is no checked-in `priv/validation_export.exs` script.
Keep real CSVs, workbooks, rosters, and crosswalks in ignored `data/` or private
storage. The Mix tasks under `lib/mix/tasks/` are one-off helpers with specific
input filenames; read their module documentation before running them.

---

## Database management

```bash
# Destructive local reset (drop + recreate + migrate + seeds)
mix ecto.reset

# Drop only
mix ecto.drop

# Run migrations
mix ecto.migrate

# Roll back the last migration
mix ecto.rollback
```

---

## Project structure

```
lib/
├── residency_schedule/          # Domain logic (no web dependencies)
│   ├── schedules/               # Schedule context + schema
│   ├── residents/               # Resident context + schema
│   ├── rotations/               # Rotation context + schema
│   ├── importer/                # CSV/date updates and QGenda parsing
│   ├── detailed_schedules/      # Daily activities, provenance, search
│   ├── accounts/                # Individual users and login tokens
│   ├── assistant/               # Shared schedule tools and chat
│   ├── schedule_editor.ex      # Staged rotation edits
│   ├── schedule_cache.ex       # Revisioned shared schedule data
│   ├── ical.ex                  # iCal feed builder
│   └── release.ex               # Migration task for prod releases
└── residency_schedule_web/      # Phoenix web layer
    ├── plugs/require_auth.ex    # Session auth plug
    ├── controllers/             # Auth + iCal controllers
    ├── live/                    # LiveView pages
    └── components/              # Layouts

test/
├── fixtures/                    # Sample CSV files for tests
├── residency_schedule/          # Unit + integration tests for domain
└── residency_schedule_web/      # Controller + LiveView tests
```

**Rule:** All database access goes through context modules (`Schedules`, `Residents`, `Rotations`). LiveViews and controllers never call `Repo` directly.

---

## Common issues

### PostgreSQL not running

```
** (DBConnection.ConnectionError) tcp connect (localhost:5432)
```

Start PostgreSQL:
```bash
brew services start postgresql   # macOS with Homebrew
sudo systemctl start postgresql   # Linux
```

### Port 4000 already in use

```bash
lsof -nP -iTCP:4000 -sTCP:LISTEN
```

Identify the listener, then stop the appropriate development process.

### Tailwind or esbuild not downloading

If you're behind a proxy or have a slow connection, the binary download may fail silently. Try:

```bash
mix tailwind.install --force
mix esbuild.install --force
```

### Database already exists

Use `mix ecto.migrate` to update an existing local database. Use `mix ecto.reset`
only when you intend to discard its contents.
