# Development Setup

## Prerequisites

Install the following before starting:

| Tool | Version | Install |
|---|---|---|
| Elixir | ~> 1.15 | [asdf](https://asdf-vm.com) or [mise](https://mise.jdx.dev) recommended |
| Erlang/OTP | 26 or 27 | installed automatically with Elixir via asdf/mise |
| PostgreSQL | 14+ | `brew install postgresql` on macOS |
| Node | not required | esbuild/tailwind are downloaded by Mix automatically |

### Install Elixir via mise (recommended)

```bash
mise install elixir 1.18
mise install erlang 27
```

### Install Elixir via asdf

```bash
asdf plugin add elixir
asdf plugin add erlang
asdf install elixir 1.18.3
asdf install erlang 27.0
```

---

## First-time setup

### 1. Clone and install dependencies

```bash
git clone git@github.com:<your-org>/residency-schedule.git
cd residency_schedule
mix deps.get
```

### 2. Create and migrate the database

Make sure PostgreSQL is running, then:

```bash
mix ecto.setup
```

This runs `ecto.create`, `ecto.migrate`, and `priv/repo/seeds.exs` in sequence.

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

### 4. Set the access password

The app requires a password to log in. In development it defaults to `"dev-password"` (set in `config/config.exs`). You can change this without touching source code by overriding it in `config/dev.exs`:

```elixir
config :residency_schedule, access_password: "your-local-password"
```

---

## Running the development server

```bash
mix phx.server
```

Visit [http://localhost:4000](http://localhost:4000). Log in with password `dev-password` (or whatever you set above).

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

Run tests matching a pattern:

```bash
mix test --only integration
```

---

## Precommit check

Run the full precommit suite (compile with warnings-as-errors, unused deps check, format, tests):

```bash
mix precommit
```

This should pass cleanly before every push. CI enforces the same checks.

---

## Uploading a schedule CSV

After starting the server:

1. Navigate to [http://localhost:4000/upload](http://localhost:4000/upload)
2. Select a CSV file exported from the residency schedule spreadsheet
3. Click **Import Schedule**

The importer derives the academic year automatically from the dates in the file (e.g. dates starting in July 2026 → `2026–2027`). Re-importing the same year replaces existing data without duplication.

### Expected CSV format

```
Row 0: "",  "Dates", "2026-07-06", "2026-07-13", ...   ← start dates
Row 1: "",  "",      "2026-07-12", "2026-07-19", ...   ← end dates
Row 2: event annotation row (Retreat, CREOGS, etc.)    ← skipped
Row 3+: resident rows: "R4-1", "Alexis", "ONC", "HWD", ...
```

Only rows where column A matches `R[1-4]-\d+` are imported. All other rows are skipped.

### Generating a validation CSV

To verify imported data against the source schedule, run:

```bash
MIX_ENV=dev mix run priv/validation_export.exs
```

This writes `priv/validation_export.csv` with one column per calendar day, showing each resident's rotation assignment for the full year.

---

## Database management

```bash
# Reset (drop + recreate + migrate)
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
│   ├── importer/                # CSV parser + schedule importer
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
lsof -ti:4000 | xargs kill
```

### Tailwind or esbuild not downloading

If you're behind a proxy or have a slow connection, the binary download may fail silently. Try:

```bash
mix tailwind.install --force
mix esbuild.install --force
```

### Database already exists

```bash
mix ecto.drop && mix ecto.setup
```
