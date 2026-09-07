# CLAUDE.md — Residency Schedule

This file is read automatically by Claude Code on every session. Follow all rules
here without exception unless the user explicitly overrides one for a specific task.

---

## Project Overview

An Elixir / Phoenix LiveView application that parses OB/GYN residency schedules from
CSV uploads and visualizes them as interactive Gantt grids, monthly calendars, and
comparison views. See `residency_schedule_plan_v2.md` in the repo root for the full
architectural spec.

---

## Code Style Rules

## **NOTE: EVERY ADDITIONAL CODE WRITTEN THAT ADDS BEHAVIOR MUST BE ACCOMPANIED BY A TEST THAT VALIDATES SAID BEHAVIOR** 

### 1. Single Responsibility — One Function, One Job

Every function does exactly one thing. If you find yourself writing `and` in a
`@doc` description, the function needs to be split.

```elixir
# ✅ CORRECT — each step is its own function
def parse(csv_binary) do
  csv_binary
  |> decode_rows()
  |> extract_date_slots()
  |> extract_resident_rows()
  |> build_parsed_residents()
end

# ❌ WRONG — decoding and filtering mixed together
def parse(csv_binary) do
  csv_binary
  |> NimbleCSV.RFC4180.parse_string()
  |> Enum.filter(&resident_row?/1)  # filtering inside parsing
  |> ...
end
```

### 2. Pipe-First Data Transformation

All multi-step data transformations use `|>`. The input data flows top to bottom.
Avoid intermediate variables when a pipe expresses intent more clearly.

```elixir
# ✅ CORRECT
def build_rotation(slot, cell_value) do
  cell_value
  |> String.trim()
  |> lookup_rotation_type()
  |> build_rotation_entry(slot)
end

# ❌ WRONG — named intermediates obscure the flow
def build_rotation(slot, cell_value) do
  trimmed = String.trim(cell_value)
  type = lookup_rotation_type(trimmed)
  build_rotation_entry(type, slot)
end
```

Acceptable exceptions: when a value is used more than once, or when naming it
genuinely improves readability (e.g. a complex pattern match result).

### 3. Doctests on Every Public Function

Every public function (`def`, not `defp`) must have a `@doc` block with at least one
doctest demonstrating the happy path. The doctest must be runnable — use real values,
not placeholders.

```elixir
@doc """
Derives the academic year label from the start year integer.

    iex> ResidencySchedule.Schedules.academic_year_label(2026)
    "2026–2027"

    iex> ResidencySchedule.Schedules.academic_year_label(2023)
    "2023–2024"
"""
def academic_year_label(start_year) do
  "#{start_year}–#{start_year + 1}"
end
```

Rules for doctests:
- Use `iex>` format, not prose descriptions of what the function returns
- Cover the happy path only — edge cases belong in unit tests
- The doctests should always exercise the most intended pathway, for example if there is a collection being parsed, the test should not have an empty collection as the test data.
- If the function returns a struct or large map, test a specific field:
  `iex> result.rotation_type` rather than the whole struct
- Doctests for functions that hit the database are **exempt** — use unit tests instead

### 4. Unit Tests — Cover Every Branch

For every function (public and private via the module's public interface), write
`ExUnit` tests that exercise every branch: every `case` arm, every `cond` clause,
every `if`/`else`, every `with` failure path.

**File naming:** `test/residency_schedule/<context>/<module>_test.exs`

**Structure:**
```elixir
defmodule ResidencySchedule.Importer.CsvParserTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Importer.CsvParser

  describe "parse_date_row/1" do
    test "parses valid ISO 8601 date strings" do
      row = ["", "Dates", "2026-07-06", "2026-07-13"]
      assert CsvParser.parse_date_row(row) == [~D[2026-07-06], ~D[2026-07-13]]
    end

    test "drops empty trailing cells" do
      row = ["", "Dates", "2026-07-06", "", ""]
      assert CsvParser.parse_date_row(row) == [~D[2026-07-06]]
    end

    test "drops nil cells" do
      row = ["", "Dates", "2026-07-06", nil]
      assert CsvParser.parse_date_row(row) == [~D[2026-07-06]]
    end
  end

  describe "fix_year_rollover/1" do
    test "leaves dates unchanged when all ascending" do
      dates = [~D[2026-07-06], ~D[2026-08-01], ~D[2026-09-15]]
      assert CsvParser.fix_year_rollover(dates) == dates
    end

    test "increments year after rollover point" do
      dates = [~D[2026-11-01], ~D[2026-12-01], ~D[2026-01-01], ~D[2026-02-01]]
      result = CsvParser.fix_year_rollover(dates)
      assert Enum.at(result, 2) == ~D[2027-01-01]
      assert Enum.at(result, 3) == ~D[2027-02-01]
    end

    test "handles single-element list" do
      assert CsvParser.fix_year_rollover([~D[2026-07-06]]) == [~D[2026-07-06]]
    end
  end
end
```

**Branch coverage checklist** — for each function, tests must cover:
- Happy path (already in doctest, but also in ExUnit for completeness)
- Each `{:error, reason}` return path
- Empty input / nil input where applicable
- Edge cases specific to the domain (e.g. a backtick junk cell, unknown rotation
  abbreviation, resident row with no rotations)

### 5. Integration Tests

Integration tests live in `test/residency_schedule_web/` and use
`Phoenix.ConnTest` for controllers and `Phoenix.LiveViewTest` for LiveViews.
They run against a real test database via `Ecto.Adapters.SQL.Sandbox`.

**What integration tests must cover:**

#### CSV Upload Pipeline (end-to-end)
```elixir
# test/residency_schedule/importer/integration_test.exs
defmodule ResidencySchedule.Importer.IntegrationTest do
  use ResidencySchedule.DataCase  # sets up sandbox

  test "full pipeline: CSV binary → database rows" do
    csv = File.read!("test/fixtures/sample.csv")

    assert {:ok, %{residents: r_count, rotations: rot_count}} =
             ScheduleImporter.import_csv(csv)

    assert r_count > 0
    assert rot_count > 0

    # Spot-check a known resident from the fixture
    resident = Residents.get_resident_by_position!("R4-1")
    assert resident.name == "Briar"
    assert length(resident.rotations) > 0
  end

  test "re-importing the same CSV replaces data without duplication" do
    csv = File.read!("test/fixtures/sample.csv")
    {:ok, first} = ScheduleImporter.import_csv(csv)
    {:ok, second} = ScheduleImporter.import_csv(csv)
    assert first.residents == second.residents
    assert first.rotations == second.rotations
  end

  test "importing a second academic year does not affect the first" do
    csv_2023 = File.read!("test/fixtures/sample.csv")
    csv_2026 = File.read!("test/fixtures/sample_2026.csv")
    {:ok, _} = ScheduleImporter.import_csv(csv_2023)
    {:ok, _} = ScheduleImporter.import_csv(csv_2026)

    assert Schedules.get_by_year!(2023).label == "2023–2024"
    assert Schedules.get_by_year!(2026).label == "2026–2027"
    # Both years have residents
    assert length(Residents.list_residents_for_schedule(2023)) > 0
    assert length(Residents.list_residents_for_schedule(2026)) > 0
  end
end
```

#### LiveView Integration Tests
```elixir
# test/residency_schedule_web/live/schedule_live_test.exs
defmodule ResidencyScheduleWeb.ScheduleLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  setup :authenticate_session  # helper that sets :authenticated in session

  test "renders schedule grid after upload", %{conn: conn} do
    seed_schedule()  # inserts fixture data via importer
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "[data-resident='R4-1']")
  end

  test "year filter hides residents from other years", %{conn: conn} do
    seed_schedule()
    {:ok, view, _html} = live(conn, "/")
    view |> element("[phx-click='filter_year'][phx-value-year='4']") |> render_click()
    assert has_element?(view, "[data-resident='R4-1']")
    refute has_element?(view, "[data-resident='R1-1']")
  end
end
```

**Test fixture:** Check in `test/fixtures/sample.csv` — this should be the
actual 2023-2024 CSV with names replaced by pseudonyms if privacy is a concern.
A second fixture `test/fixtures/sample_2026.csv` with a different start
year is needed for multi-year tests (can be a modified copy of the first).

---

## Module Conventions

### Contexts are the public API

All database access goes through context modules (`Residents`, `Rotations`,
`Schedules`). LiveViews and controllers never call `Repo` directly.

```elixir
# ✅ CORRECT — LiveView delegates to context
def handle_event("hover_day", %{"date" => date_str}, socket) do
  date = Date.from_iso8601!(date_str)
  detail = Rotations.list_rotations_for_date(date, socket.assigns.schedule.id)
  {:noreply, assign(socket, day_detail: detail)}
end

# ❌ WRONG — LiveView queries directly
def handle_event("hover_day", %{"date" => date_str}, socket) do
  date = Date.from_iso8601!(date_str)
  rotations = Repo.all(from r in Rotation, where: ...)
  {:noreply, assign(socket, day_detail: rotations)}
end
```

### Error handling with `{:ok, _} / {:error, _}`

All functions that can fail return tagged tuples. Never raise from a public
context function — let the caller decide how to handle errors.

```elixir
# ✅ CORRECT
def import_csv(binary) do
  with {:ok, parsed, warnings} <- CsvParser.parse(binary),
       {:ok, result}            <- ScheduleImporter.import(parsed) do
    {:ok, result, warnings}
  else
    {:error, reason} -> {:error, reason}
  end
end

# ❌ WRONG — raises on bad input
def import_csv(binary) do
  parsed = CsvParser.parse!(binary)
  ScheduleImporter.import!(parsed)
end
```

Exception: `get_resident!/1` and similar bang functions are acceptable for cases
where a missing record is a programmer error (e.g. following a valid FK), not user input.

### Private functions are prefixed with intent

Name private helpers to describe what they do to the data, not what they are:

```elixir
defp reject_empty_cells(cells)       # ✅
defp filter_cells(cells)             # ❌ — filter to what?

defp normalize_rotation_key(string)  # ✅
defp process_string(string)          # ❌ — process how?
```

---

## Testing Utilities

### DataCase helpers

Add these to `test/support/data_case.ex` for use across all context tests:

```elixir
def seed_schedule(year \\ 2023) do
  csv = File.read!("test/fixtures/sample.csv")
  {:ok, result, _warnings} = ResidencySchedule.Importer.ScheduleImporter.import_csv(csv)
  result
end
```

### ConnCase authentication helper

Add to `test/support/conn_case.ex`:

```elixir
def authenticate_session(%{conn: conn}) do
  conn = Plug.Test.init_test_session(conn, authenticated: true)
  %{conn: conn}
end
```

Use as `setup :authenticate_session` in any LiveView or controller test that sits
behind the auth plug.

---

## Deployment

### Never commit secrets

All production secrets live in `/home/deploy/residency_schedule/.env` on the
server and in GitHub Actions Secrets. They must never appear in source code,
`config/` files, or be logged.

The variables required at runtime are:
- `DATABASE_URL` — server-only, never in GitHub Secrets
- `ACCESS_PASSWORD` — server-only, never in GitHub Secrets
- `SECRET_KEY_BASE` — GitHub Secret (used at build time for asset digests)
- `PHX_HOST` — GitHub Secret
- `CHAT_ENABLED` — optional; GitHub Variable, written to the server `.env` by the deploy
- `ANTHROPIC_API_KEY` — optional; GitHub Secret, written to the server `.env` by the deploy; required at boot when `CHAT_ENABLED=true`

### `config/runtime.exs` is the only place for prod config

All production configuration reads from `System.fetch_env!/1`. Use
`System.fetch_env!` (bang) not `System.get_env` so missing vars fail loudly
at boot rather than silently misbehaving.

### The Release module is required

`ResidencySchedule.Release.migrate/0` must exist and work correctly. It is
called by the deploy script before the service restarts. Never rely on
`mix ecto.migrate` in production — it requires the Mix toolchain which is
not present in a compiled release.

### GitHub Actions workflow rules

- The `deploy` job must declare `needs: test` — deploys never run if tests fail
- Migrations run **before** the service restarts, not after
- The rollback swap in the deploy script must not be removed or simplified —
  it is the recovery path when a bad release makes it past tests
- Asset compilation (`mix assets.deploy`) runs in CI, not on the server

### What Not to Do in Deployment

- **No `mix` commands on the server** — use release commands only
- **No secrets in `config/config.exs` or `config/prod.exs`** — runtime only
- **No deploys that skip tests** — the `needs: test` gate is not optional
- **No direct pushes that bypass the workflow** — always push to `main` and
  let the workflow run

---

## What Not to Do

- **No `Repo` calls outside context modules**
- **No multi-responsibility functions** — if in doubt, split it
- **No public function without a doctest**
- **No untested branch** — every `case`/`cond`/`if` arm needs a test
- **No hardcoded academic years** — all year logic derives from parsed dates
- **No `String.downcase` for rotation lookups** — use `String.trim` + a
  case-insensitive match via `Map.get(abbrev_map, String.trim(val))` with a
  downcased key map, not by downcasing the input and hoping for the best
- **No `IO.inspect` left in committed code**
