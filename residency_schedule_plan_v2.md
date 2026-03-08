# OB/GYN Residency Schedule Visualizer — Build Plan (v2)

> Updated after inspecting the actual CSV export of `2023-2024_Resident_Schedules_xlsx`.

---

## Tech Stack

| Layer | Choice | Notes |
|---|---|---|
| Language | Elixir | |
| Web framework | Phoenix 1.7+ with LiveView | |
| Database | PostgreSQL | |
| ORM | Ecto | |
| Stylesheet | TailwindCSS (bundled with Phoenix) | |
| CSV parsing | `NimbleCSV` | Simple, fast, zero config |

---

## Actual CSV Structure (ground truth)

```
Row 0  →  ["", "Dates", "2023-07-03", "2023-07-08", ...]   ← start dates, col B = literal "Dates"
Row 1  →  ["", "",      "2023-07-07", "2023-07-09", ...]   ← end dates
Row 2  →  ["", "",      "", ..., "Retreat", ..., "CREOGS", ..., "Research Day", ...]  ← event annotations (skip)
Row 3+ →  resident rows OR separator rows
Last 2 rows → legend/summary table (skip)
```

**Resident row:** `["R4-1", "Alexis", "ONC", "HWD", "ONC", "", ...]`

**Separator row between year groups:** col A is blank, col B is blank, occasional annotation
cells like `"HWN"` — detected by col A being empty.

**Legend rows at bottom:** col A is blank, cells contain rotation labels and resident names.
Skip all rows where col A does not match `~r/^R[1-4]-\d+$/`.

---

## ⚠️ Known Data Issues in the Source File

### 1. Year rollover bug in dates
Dates from July–December are `2023-XX-XX` (correct). Dates from January onward are
labeled `2023-01-01`, `2023-02-05`, etc. — but they should be `2024`. The Excel source
has the wrong year for the second half of the academic year.

**Fix in parser:** After parsing all dates into a list, walk through them in order. When
a parsed date is *earlier than the previous date*, increment all subsequent dates' year by 1.

```elixir
defp fix_year_rollover(dates) do
  dates
  |> Enum.reduce({nil, []}, fn date, {prev, acc} ->
    date = if prev && Date.compare(date, prev) == :lt do
      %{date | year: date.year + 1}
    else
      date
    end
    {date, [date | acc]}
  end)
  |> elem(1)
  |> Enum.reverse()
end
```

### 2. Trailing whitespace in names
Several names have trailing spaces: `"Kathryn "`, `"Danielle "`, `"Chima "`, etc.
Always `String.trim/1` the name field.

### 3. Backtick artifact in R2-1
`R2-1` (Chima) has a backtick `` ` `` as one cell value. Treat any unrecognized
abbreviation as a parse warning (collect and report), not a hard failure.

---

## Complete Rotation Type Registry

```elixir
@rotation_abbreviations %{
  "AMB"      => :ambulatory,              # Ambulatory
  "AWAY"     => :away_rotation,           # Away Rotation
  "Elective" => :elective,               # Elective
  "FLOAT"    => :float,                  # Float
  "GYN"      => :strong_gynecology,      # Gynecology – Strong Memorial Hospital
  "HGYN"     => :highland_gynecology,    # Gynecology – Highland Hospital
  "HHOB"     => :highland_obstetrics,    # Obstetrics – Highland Hospital
  "HNF"      => :highland_night_float,   # Night Float – Highland Hospital
  "HWD"      => :highland_weekend_days,  # Weekend Days – Highland Hospital
  "HWN"      => :highland_weekend_nights,# Weekend Nights – Highland Hospital
  "NF"       => :night_float,            # Night Float – Strong Memorial Hospital
  "OB"       => :strong_obstetrics,      # Obstetrics – Strong Memorial Hospital
  "ONC"      => :oncology,               # Oncology – Highland Hospital
  "P"        => :post_call,              # Post Call
  "REI"      => :rei,                    # Reproductive Endocrinology & Infertility
  "SWD"      => :strong_weekend_days,    # Weekend Days – Strong Memorial Hospital
  "SWN"      => :strong_weekend_nights,  # Weekend Nights – Strong Memorial Hospital
  "Swing"    => :swing,                  # Swing Shift
  "UG"       => :urogynecology,          # Uro-Gynecology
  "USN"      => :unknown,                # Unknown (TBD)
  "Vac"      => :vacation,               # Vacation
  # empty cell → not stored (day off)
  # "`"       → parse warning, not stored (junk cell in R2-1)
}
```

Use **case-insensitive** matching when looking up abbreviations.

---

## Data Models

### `schedules` table

Represents one uploaded academic year. The academic year is inferred from the earliest
date in the file (e.g. a file starting in July 2026 → `academic_year: 2026`,
label: `"2026–2027"`). Re-uploading a file for the same year replaces that year's data.
Multiple years coexist in the database and are selectable in the UI.

| Column | Type | Notes |
|---|---|---|
| `id` | `bigserial` PK | |
| `academic_year` | `integer` | Start year, e.g. `2026` for the 2026–2027 cycle |
| `label` | `string` | Display label, e.g. `"2026–2027"`, derived automatically |
| `inserted_at` / `updated_at` | `utc_datetime` | |

`unique_index(:schedules, [:academic_year])`

### `residents` table

| Column | Type | Notes |
|---|---|---|
| `id` | `bigserial` PK | |
| `schedule_id` | `bigint` FK → schedules | |
| `position_code` | `string` | `"R4-1"` |
| `residency_year` | `integer` | 1–4 |
| `schedule_number` | `integer` | 1–N |
| `name` | `string` | Trimmed |
| `inserted_at` / `updated_at` | `utc_datetime` | |

`unique_index(:residents, [:schedule_id, :position_code])`

### `rotations` table

| Column | Type | Notes |
|---|---|---|
| `id` | `bigserial` PK | |
| `resident_id` | `bigint` FK → residents | |
| `rotation_type` | `string` | Stored as atom name string, e.g. `"post_call"` |
| `start_date` | `date` | Corrected for year rollover |
| `end_date` | `date` | Corrected for year rollover |
| `slot_index` | `integer` | 0-based column index; useful for display ordering |
| `inserted_at` / `updated_at` | `utc_datetime` | |

Indexes:
- `index(:rotations, [:resident_id, :start_date])`
- `index(:rotations, [:rotation_type])`

---

## Application Directory Structure

```
lib/
├── residency_schedule/
│   ├── schedules/
│   │   ├── schedule.ex
│   │   └── schedules.ex
│   ├── residents/
│   │   ├── resident.ex
│   │   └── residents.ex
│   ├── rotations/
│   │   ├── rotation.ex
│   │   └── rotations.ex
│   ├── ical.ex                    # iCal feed builder
│   └── importer/
│       ├── csv_parser.ex
│       └── schedule_importer.ex
└── residency_schedule_web/
    ├── plugs/
    │   └── require_auth.ex        # Session-based auth plug
    ├── controllers/
    │   ├── auth_controller.ex     # Login / logout
    │   └── ical_controller.ex     # .ics feed endpoint
    ├── live/
    │   ├── upload_live/
    │   │   └── index.ex
    │   ├── schedule_live/
    │   │   ├── index.ex           # Main Gantt grid
    │   │   └── index.html.heex
    │   ├── calendar_live/
    │   │   ├── index.ex           # Monthly calendar + hover modal
    │   │   └── index.html.heex
    │   ├── compare_live/
    │   │   ├── index.ex           # Shift overlap comparison
    │   │   └── index.html.heex
    │   └── resident_live/
    │       ├── show.ex
    │       └── show.html.heex
    └── components/
        ├── rotation_badge.ex
        └── gantt_row.ex
```

---

## Parser Module: `ResidencySchedule.Importer.CsvParser`

### Intermediate structs

```elixir
defmodule ResidencySchedule.Importer.CsvParser do

  defstruct [:position_code, :residency_year, :schedule_number, :name, :rotations]
  # rotations: list of %{slot_index: integer, start_date: Date.t(), end_date: Date.t(), rotation_type: atom}
  # Empty cells are filtered out — no rotation entry for days off

  @resident_row_pattern ~r/^R([1-4])-(\d+)$/
end
```

### Parsing algorithm (step by step)

```
1. Parse CSV with NimbleCSV (comma separator, no header row)
   → list of string lists

2. Extract row 0: strip first 2 elements → raw_starts (list of strings)
3. Extract row 1: strip first 2 elements → raw_ends (list of strings)

4. Parse dates:
   a. Map each string through Date.from_iso8601!/1
   b. Run fix_year_rollover/1 on both lists (see above)
   c. zip: slots = Enum.zip(raw_starts, raw_ends)
            |> Enum.with_index()
            → [{slot_index, {start_date, end_date}}, ...]

5. Filter to only resident rows:
   - Keep rows where col A (index 0) matches @resident_row_pattern
   - This automatically discards: header rows, separator rows,
     event annotation rows, legend rows at bottom

6. For each resident row:
   a. Match col A against @resident_row_pattern
      → extract residency_year (integer) and schedule_number (integer)
   b. col B (index 1): String.trim/1 → name
   c. cols C+ (index 2..): zip with indexed slots
   d. For each {cell_value, slot_index, start_date, end_date}:
      - Skip if cell_value is nil or String.trim(cell_value) == ""
      - Normalize: String.trim(cell_value)
      - Look up in @rotation_abbreviations (case-insensitive)
      - If found: emit rotation entry
      - If not found: add to warnings list (don't crash)

7. Return {:ok, residents, warnings} | {:error, reason}
   where warnings is a list of {position_code, slot_index, unknown_value}
```

### Academic year derivation

After parsing and correcting dates, derive the academic year from the earliest date in
the schedule. Residency programs run July–June, so the academic year is the calendar
year of July (the start month).

```elixir
defp derive_academic_year(dates) do
  earliest = Enum.min(dates, Date)
  # Academic year always starts in July; earliest date should be in July
  earliest.year
end

defp academic_year_label(year), do: "#{year}–#{year + 1}"
```

This means a file with dates starting `2026-07-03` produces `academic_year: 2026`,
`label: "2026–2027"` — regardless of what the filename says.

### Year rollover fix
`Date.from_iso8601!/1` handles `"YYYY-MM-DD"` format directly. The last two columns of
row 0 and row 1 are empty strings — filter these out before zipping (drop any element
that doesn't parse as a valid date).

```elixir
defp parse_date_row(cells) do
  cells
  |> Enum.drop(2)          # drop col A and col B
  |> Enum.reject(&(&1 == "" or is_nil(&1)))
  |> Enum.map(&Date.from_iso8601!/1)
end
```

---

## Importer Module: `ResidencySchedule.Importer.ScheduleImporter`

**Strategy:** Upsert the schedule record for the given academic year, then wipe and
reload all residents and rotations for that year only. Other years are untouched.

```elixir
def import(parsed_residents, academic_year, label) do
  Repo.transaction(fn ->
    # 1. Upsert schedule (conflict on academic_year → update label + updated_at)
    schedule = upsert_schedule!(academic_year, label)

    # 2. Delete all residents for this schedule (cascades to rotations via FK)
    Repo.delete_all(from r in Resident, where: r.schedule_id == ^schedule.id)

    # 3. Bulk insert residents, then rotations
    for parsed <- parsed_residents do
      resident = insert_resident!(schedule.id, parsed)
      insert_rotations!(resident.id, parsed.rotations)
    end
  end)
end
```

---

## Context Modules

### `ResidencySchedule.Residents`

```elixir
list_residents()
  # Returns all residents ordered by residency_year ASC, schedule_number ASC

list_residents_by_year(year :: integer)
  # Filter to a single residency year

get_resident!(id)
  # Preloads rotations ordered by start_date

get_resident_by_position!(position_code :: String.t())
```

### `ResidencySchedule.Rotations`

```elixir
list_rotations_for_resident(resident_id :: integer)

list_rotations_in_range(start_date :: Date.t(), end_date :: Date.t())
  # Used to build the schedule grid for a given visible window

list_rotations_by_type(rotation_type :: String.t())
  # For filtering/highlighting by rotation type

rotation_type_label(rotation_type :: String.t()) :: String.t()
  # Human-readable label for display

rotation_type_color(rotation_type :: String.t()) :: String.t()
  # Tailwind CSS classes for color-coding
```

---

## LiveView Pages

### `UploadLive.Index` — `/upload`

- Phoenix `allow_upload/3` with `accept: ~w(.csv)`, `max_file_size: 5_000_000`
- On consume: read binary → `CsvParser.parse/1` → `ScheduleImporter.import/1`
- Surface all warnings (unknown abbreviations) in a yellow callout box
- On success: redirect to `/`

### `ScheduleLive.Index` — `/` (Main Gantt View)

**Assigns:**
```elixir
assigns = %{
  schedules: [...],         # All available academic years for the year-picker
  schedule: %Schedule{},    # Currently selected schedule
  residents: [...],         # Grouped by year: %{1 => [...], 2 => [...], ...}
  slots: [...],             # [{slot_index, start_date, end_date}, ...]
  filter_year: nil,         # nil | 1 | 2 | 3 | 4
  filter_type: nil,         # nil | rotation_type string
  date_range: {start, end}  # Visible window (default: full schedule)
}
```

The schedule defaults to the most recent academic year. A year-picker control lets
users switch between uploaded schedules (e.g. `"2023–2024" | "2026–2027"`).

Each cell:
- Empty (gray background) if no rotation
- Colored badge showing rotation abbreviation if rotation present
- `phx-click="select_resident"` to navigate to detail view

**Controls:**
- Year filter tabs: `All | R1 | R2 | R3 | R4`
- Rotation type filter dropdown
- "Upload new schedule" link

### `ResidentLive.Show` — `/residents/:id`

- Single resident's full-year timeline
- Horizontal timeline: colored blocks proportional to date span
- Each block shows rotation type label + date range
- Back button to main grid

---

## Rotation Color Palette

Colors are grouped by hospital/category for visual consistency:
- **Strong Memorial** rotations: blue family
- **Highland Hospital** rotations: cyan/fuchsia family
- **Call/nights** rotations: indigo family
- **Administrative/other**: neutrals and greens

```elixir
@rotation_colors %{
  # Strong Memorial Hospital
  "strong_obstetrics"      => "bg-blue-500 text-white",
  "strong_gynecology"      => "bg-blue-400 text-white",
  "strong_weekend_days"    => "bg-blue-300 text-gray-800",
  "strong_weekend_nights"  => "bg-blue-800 text-white",
  # Highland Hospital
  "highland_obstetrics"    => "bg-cyan-500 text-white",
  "highland_gynecology"    => "bg-fuchsia-500 text-white",
  "oncology"               => "bg-rose-700 text-white",
  "highland_weekend_days"  => "bg-cyan-300 text-gray-800",
  "highland_weekend_nights"=> "bg-cyan-800 text-white",
  # Night float / call
  "night_float"            => "bg-indigo-700 text-white",
  "highland_night_float"   => "bg-indigo-400 text-white",
  "post_call"              => "bg-indigo-100 text-indigo-900",
  # Subspecialty / other clinical
  "ambulatory"             => "bg-teal-500 text-white",
  "rei"                    => "bg-yellow-500 text-gray-900",
  "urogynecology"          => "bg-orange-400 text-white",
  "elective"               => "bg-violet-400 text-white",
  "away_rotation"          => "bg-violet-200 text-violet-900",
  "swing"                  => "bg-lime-500 text-white",
  "unknown"                => "bg-gray-400 text-white",
  # Administrative
  "vacation"               => "bg-emerald-400 text-white",
  "float"                  => "bg-gray-300 text-gray-700",
}
```

---

---

## Feature Specifications

### 1. Password Protection

A single shared password grants view access to the entire app. No user accounts.
The password is stored as an environment variable and never in source control.

**Implementation:** A custom `Plug` in the Phoenix pipeline checks for an
`:authenticated` key in the session. If absent, it redirects to `/login`.
On successful login, it sets the session key and redirects back.

```elixir
# lib/residency_schedule_web/plugs/require_auth.ex
defmodule ResidencyScheduleWeb.Plugs.RequireAuth do
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_session(conn, :authenticated) do
      conn
    else
      conn
      |> redirect(to: "/login")
      |> halt()
    end
  end
end
```

```elixir
# In router.ex — protect all app routes, leave /login open
pipeline :authenticated do
  plug ResidencyScheduleWeb.Plugs.RequireAuth
end

scope "/", ResidencyScheduleWeb do
  pipe_through :browser
  get  "/login",  AuthController, :show
  post "/login",  AuthController, :create
  post "/logout", AuthController, :delete
end

scope "/", ResidencyScheduleWeb do
  pipe_through [:browser, :authenticated]
  live "/",              ScheduleLive.Index,  :index
  live "/upload",        UploadLive.Index,    :index
  live "/residents/:id", ResidentLive.Show,   :show
  live "/calendar",      CalendarLive.Index,  :index
  live "/compare",       CompareLive.Index,   :index
end
```

**Password check in `AuthController`:**
```elixir
def create(conn, %{"password" => password}) do
  expected = Application.fetch_env!(:residency_schedule, :access_password)
  if Plug.Crypto.secure_compare(password, expected) do
    conn
    |> put_session(:authenticated, true)
    |> redirect(to: "/")
  else
    conn
    |> put_flash(:error, "Incorrect password.")
    |> render(:show)
  end
end
```

Store the password in `config/runtime.exs`:
```elixir
config :residency_schedule, access_password: System.fetch_env!("ACCESS_PASSWORD")
```

`Plug.Crypto.secure_compare/2` is used instead of `==` to prevent timing attacks.

---

### 2. iCal Feed (Google Calendar Integration)

Each resident gets a subscribable calendar feed at a stable URL. Anyone with the
link can add it to Google Calendar, Apple Calendar, or Outlook and it will stay
in sync as schedules are updated.

**URL:** `GET /residents/:id/calendar.ics`

This is a plain Phoenix controller action (not LiveView) that returns an iCal
formatted response.

```elixir
# lib/residency_schedule_web/controllers/ical_controller.ex
defmodule ResidencyScheduleWeb.IcalController do
  use ResidencyScheduleWeb, :controller

  def show(conn, %{"id" => id}) do
    resident = Residents.get_resident!(id)  # preloads rotations
    ical = ResidencySchedule.Ical.build(resident)

    conn
    |> put_resp_content_type("text/calendar")
    |> put_resp_header("content-disposition",
         ~s(attachment; filename="#{resident.name}.ics"))
    |> send_resp(200, ical)
  end
end
```

**iCal builder** (`lib/residency_schedule/ical.ex`):

```elixir
defmodule ResidencySchedule.Ical do
  def build(resident) do
    events = Enum.map(resident.rotations, &build_event(resident, &1))

    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//ResidencySchedule//EN
    CALSCALE:GREGORIAN
    X-WR-CALNAME:#{resident.name} – Schedule
    #{Enum.join(events, "\n")}
    END:VCALENDAR
    """
  end

  defp build_event(resident, rotation) do
    uid = "rotation-#{rotation.id}@residency-schedule"
    label = Rotations.rotation_type_label(rotation.rotation_type)
    # iCal dates are YYYYMMDD; end date is exclusive so add 1 day
    dtstart = Calendar.strftime(rotation.start_date, "%Y%m%d")
    dtend   = rotation.end_date |> Date.add(1) |> Calendar.strftime("%Y%m%d")

    """
    BEGIN:VEVENT
    UID:#{uid}
    SUMMARY:#{label}
    DTSTART;VALUE=DATE:#{dtstart}
    DTEND;VALUE=DATE:#{dtend}
    DESCRIPTION:#{resident.name} – #{label}
    END:VEVENT
    """
  end
end
```

**In the resident detail view**, show a "Subscribe in Google Calendar" button:
```
https://calendar.google.com/calendar/r?cid=<url-encoded feed URL>
```

The feed URL should use the full domain (e.g.
`https://yourapp.com/residents/42/calendar.ics`) so Google can fetch it remotely.
Google Calendar's "Add by URL" feature will subscribe and poll for updates.

---

### 3. Calendar View with Day Hover Modal

A monthly calendar grid where hovering any day shows a popover listing every
resident on shift that day, grouped by rotation type/service.

**Route:** `GET /calendar`

**LiveView state:**
```elixir
assigns = %{
  schedule: %Schedule{},       # Currently selected academic year
  current_month: ~D[2026-07-01],
  hovered_date: nil,           # Date | nil
  day_detail: []               # [{rotation_type, [resident_name, ...]}, ...]
}
```

**Calendar grid:** 7-column table, one cell per day. Days outside the current month
are rendered dimmed. Each day cell:

```heex
<td
  phx-mouseenter="hover_day"
  phx-value-date={Date.to_iso8601(day)}
  phx-mouseleave="clear_hover"
  class="relative h-16 border border-gray-200 cursor-default"
>
  <span class="text-sm"><%= day.day %></span>
  <%= if has_rotations?(@rotation_index, day) do %>
    <div class="flex flex-wrap gap-0.5 mt-1">
      <!-- small colored dots, one per rotation type present that day -->
    </div>
  <% end %>
</td>
```

**Event handler:**
```elixir
def handle_event("hover_day", %{"date" => date_str}, socket) do
  date = Date.from_iso8601!(date_str)
  detail = Rotations.list_rotations_for_date(date, socket.assigns.schedule.id)
           |> group_by_rotation_type()
  {:noreply, assign(socket, hovered_date: date, day_detail: detail)}
end

def handle_event("clear_hover", _params, socket) do
  {:noreply, assign(socket, hovered_date: nil, day_detail: [])}
end
```

**Query in `Rotations` context:**
```elixir
def list_rotations_for_date(date, schedule_id) do
  from(rot in Rotation,
    join: res in assoc(rot, :resident),
    where: res.schedule_id == ^schedule_id,
    where: rot.start_date <= ^date and rot.end_date >= ^date,
    preload: [resident: res],
    order_by: [rot.rotation_type, res.residency_year, res.schedule_number]
  )
  |> Repo.all()
end
```

**Popover/modal** renders as an absolutely-positioned div anchored to the hovered
cell, showing:

```
Monday, July 6
─────────────────────────
Night Float – Strong
  • Jane Doe (R2)
Obstetrics – Strong
  • John Smith (R4)
  • Maria Lopez (R1)
Vacation
  • Alex Kim (R3)
```

Use `phx-click-away` on the popover to dismiss it.

**Performance note:** Rather than querying on every hover, pre-load the full month's
rotations on mount and `current_month` change into a `Map` keyed by date. Hover events
then do a local map lookup with no DB round-trip:

```elixir
# On mount / month change:
rotation_index =
  Rotations.list_rotations_for_month(year, month, schedule_id)
  |> Enum.flat_map(fn rot ->
       Date.range(rot.start_date, rot.end_date)
       |> Enum.map(&{&1, rot})
     end)
  |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
```

---

### 4. Co-Service Day Comparison

Two dropdown selectors, each listing every resident in the current schedule.
Select two residents and see every day they were on the **same service at the same
time**, plus a total count. "Same service, same day" means identical `rotation_type`
on the same calendar date.

**Route:** `GET /compare`

**LiveView state:**
```elixir
assigns = %{
  schedule: %Schedule{},
  residents: [...],        # All residents for dropdown population
  resident_a_id: nil,
  resident_b_id: nil,
  co_service_days: [],     # [{date, rotation_type, label}, ...]
  total_days: 0
}
```

**Query in `Rotations` context:**

Use a Postgres `generate_series` to expand each rotation into individual days,
then inner-join on both `date` and `rotation_type`:

```elixir
def list_co_service_days(resident_a_id, resident_b_id) do
  from(a in Rotation,
    join: b in Rotation,
    on: b.resident_id == ^resident_b_id and b.rotation_type == a.rotation_type,
    where: a.resident_id == ^resident_a_id,
    # Find the overlapping date window between the two matching rotations
    where: a.start_date <= b.end_date and a.end_date >= b.start_date,
    # Expand the overlap window into individual days via generate_series
    join: day in fragment(
      "generate_series(GREATEST(?, ?), LEAST(?, ?), '1 day'::interval) AS day",
      a.start_date, b.start_date, a.end_date, b.end_date
    ), on: true,
    select: %{
      date:          fragment("(?::date)", day),
      rotation_type: a.rotation_type
    },
    order_by: fragment("(?::date)", day)
  )
  |> Repo.all()
end
```

This returns one row per shared day, already ordered chronologically.
The total count is just `length(co_service_days)`.

**UI layout:**

```
Compare Schedules
─────────────────────────────────────────────────
[Jane Doe (R2) ▾]            [John Smith (R4) ▾]

  14 days working together

  ┌─────────────────────────────────────────┐
  │ Service              │ Days             │
  ├─────────────────────────────────────────┤
  │ Obstetrics – Strong  │  6 days          │
  │ Ambulatory           │  5 days          │
  │ Night Float – Strong │  3 days          │
  └─────────────────────────────────────────┘

  Jul 24  Obstetrics – Strong
  Jul 25  Obstetrics – Strong
  Jul 26  Obstetrics – Strong
  ...
```

The summary table at the top groups days by service so it's easy to see
where two residents spend the most time together. Below it, the full day-by-day
list is rendered with color-coded rotation badges.

The dropdowns use `phx-change="select_resident_a"` / `"select_resident_b"` events.
Results update reactively with no page reload.

---

## mix.exs Dependencies

```elixir
defp deps do
  [
    {:phoenix, "~> 1.7"},
    {:phoenix_ecto, "~> 4.4"},
    {:ecto_sql, "~> 3.10"},
    {:postgrex, ">= 0.0.0"},
    {:phoenix_html, "~> 4.0"},
    {:phoenix_live_reload, "~> 1.2", only: :dev},
    {:phoenix_live_view, "~> 0.20"},
    {:heroicons, "~> 0.5"},
    {:telemetry_metrics, "~> 0.6"},
    {:telemetry_poller, "~> 1.0"},
    {:gettext, "~> 0.20"},
    {:jason, "~> 1.2"},
    {:bandit, "~> 1.2"},
    {:nimble_csv, "~> 1.2"}   # CSV parsing
  ]
end
```

---

## Database Migrations

### Migration 1: schedules

```elixir
create table(:schedules) do
  add :academic_year, :integer, null: false
  add :label,         :string,  null: false
  timestamps(type: :utc_datetime)
end

create unique_index(:schedules, [:academic_year])
```

### Migration 2: residents

```elixir
create table(:residents) do
  add :schedule_id,     references(:schedules, on_delete: :delete_all), null: false
  add :position_code,   :string,  null: false
  add :residency_year,  :integer, null: false
  add :schedule_number, :integer, null: false
  add :name,            :string,  null: false
  timestamps(type: :utc_datetime)
end

create unique_index(:residents, [:schedule_id, :position_code])
create index(:residents, [:schedule_id, :residency_year, :schedule_number])
```

### Migration 3: rotations

```elixir
create table(:rotations) do
  add :resident_id,   references(:residents, on_delete: :delete_all), null: false
  add :rotation_type, :string,  null: false
  add :start_date,    :date,    null: false
  add :end_date,      :date,    null: false
  add :slot_index,    :integer, null: false
  timestamps(type: :utc_datetime)
end

create index(:rotations, [:resident_id])
create index(:rotations, [:resident_id, :start_date])
create index(:rotations, [:rotation_type])
```

---

---

## Deployment — Digital Ocean via GitHub Actions

### Infrastructure Overview

| Component | Choice | Notes |
|---|---|---|
| Hosting | Digital Ocean Droplet | Ubuntu 24.04 LTS, $12/mo 2GB RAM sufficient |
| Process manager | systemd | Manages the Phoenix release as a service |
| Reverse proxy | Nginx | Terminates SSL, proxies to Phoenix on port 4000 |
| SSL | Let's Encrypt via Certbot | Auto-renewing |
| Database | Managed PostgreSQL (DO) | Or self-hosted on the same droplet for cost |
| Deployments | GitHub Actions | Push to `main` triggers build → deploy |
| Secrets | GitHub Actions Secrets | ENV vars injected at build and runtime |

---

### Elixir Release Configuration

Phoenix ships with `mix release` support. Add a runtime config file so all
secrets are read from environment variables at boot, not compile time.

**`config/runtime.exs`:**
```elixir
import Config

if config_env() == :prod do
  database_url =
    System.fetch_env!("DATABASE_URL")

  config :residency_schedule, ResidencySchedule.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: true

  secret_key_base =
    System.fetch_env!("SECRET_KEY_BASE")

  config :residency_schedule, ResidencyScheduleWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: 4000],
    secret_key_base: secret_key_base,
    url: [host: System.fetch_env!("PHX_HOST"), scheme: "https", port: 443],
    server: true

  config :residency_schedule,
    access_password: System.fetch_env!("ACCESS_PASSWORD")
end
```

**`rel/env.sh.eex`** — sourced by the release on startup, useful for setting
`RELEASE_NODE` name based on hostname:
```bash
export RELEASE_DISTRIBUTION=none
```

---

### Droplet Setup (one-time, manual)

SSH into the droplet and run these once to prepare the server:

```bash
# 1. Install Erlang/Elixir via asdf or apt
apt-get update && apt-get install -y erlang elixir

# 2. Install Nginx and Certbot
apt-get install -y nginx certbot python3-certbot-nginx

# 3. Create deploy user with limited privileges
useradd -m -s /bin/bash deploy
mkdir -p /home/deploy/residency_schedule
chown deploy:deploy /home/deploy/residency_schedule

# 4. Add GitHub Actions SSH public key to deploy user
# (paste the public key paired with the DEPLOY_SSH_KEY secret)
mkdir -p /home/deploy/.ssh
echo "<public_key>" >> /home/deploy/.ssh/authorized_keys
chmod 700 /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys

# 5. Create the runtime env file the systemd service will load
cat > /home/deploy/residency_schedule/.env << 'EOF'
DATABASE_URL=ecto://user:pass@db-host/residency_schedule_prod
SECRET_KEY_BASE=<generate with: mix phx.gen.secret>
PHX_HOST=yourdomain.com
ACCESS_PASSWORD=<your chosen password>
POOL_SIZE=10
EOF
chmod 600 /home/deploy/residency_schedule/.env
```

---

### Nginx Configuration

```nginx
# /etc/nginx/sites-available/residency_schedule
server {
    listen 80;
    server_name yourdomain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name yourdomain.com;

    ssl_certificate     /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;

    location / {
        proxy_pass         http://localhost:4000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection "upgrade";  # Required for LiveView websockets
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
```

The `Connection: upgrade` header is critical for Phoenix LiveView's WebSocket
connections to work through the proxy.

---

### systemd Service

```ini
# /etc/systemd/system/residency_schedule.service
[Unit]
Description=Residency Schedule Phoenix App
After=network.target

[Service]
Type=simple
User=deploy
WorkingDirectory=/home/deploy/residency_schedule
EnvironmentFile=/home/deploy/residency_schedule/.env
ExecStart=/home/deploy/residency_schedule/bin/residency_schedule start
ExecStop=/home/deploy/residency_schedule/bin/residency_schedule stop
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Enable once:
```bash
systemctl enable residency_schedule
systemctl daemon-reload
```

---

### GitHub Actions Workflow

**`.github/workflows/deploy.yml`:**

```yaml
name: Deploy to Digital Ocean

on:
  push:
    branches: [main]

env:
  MIX_ENV: prod
  ELIXIR_VERSION: "1.16"
  OTP_VERSION: "26"

jobs:
  test:
    name: Test
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: residency_schedule_test
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: ${{ env.ELIXIR_VERSION }}
          otp-version: ${{ env.OTP_VERSION }}

      - name: Cache deps
        uses: actions/cache@v4
        with:
          path: deps
          key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}

      - name: Cache build
        uses: actions/cache@v4
        with:
          path: _build
          key: ${{ runner.os }}-build-${{ hashFiles('**/mix.lock') }}

      - run: mix deps.get
      - run: mix compile --warnings-as-errors
      - run: mix test
        env:
          DATABASE_URL: ecto://postgres:postgres@localhost/residency_schedule_test

  deploy:
    name: Deploy
    runs-on: ubuntu-latest
    needs: test  # Only deploy if tests pass

    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: ${{ env.ELIXIR_VERSION }}
          otp-version: ${{ env.OTP_VERSION }}

      - name: Cache deps
        uses: actions/cache@v4
        with:
          path: deps
          key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}

      - run: mix deps.get --only prod
      - run: mix assets.deploy
      - run: mix release
        env:
          SECRET_KEY_BASE: ${{ secrets.SECRET_KEY_BASE }}
          PHX_HOST: ${{ secrets.PHX_HOST }}

      - name: Upload release to droplet
        uses: appleboy/scp-action@v0.1.7
        with:
          host: ${{ secrets.DEPLOY_HOST }}
          username: deploy
          key: ${{ secrets.DEPLOY_SSH_KEY }}
          source: "_build/prod/rel/residency_schedule"
          target: "/home/deploy/residency_schedule_new"
          strip_components: 4  # strips _build/prod/rel/

      - name: Swap release and restart
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.DEPLOY_HOST }}
          username: deploy
          key: ${{ secrets.DEPLOY_SSH_KEY }}
          script: |
            set -e

            # Run migrations before swapping (against live DB via env file)
            source /home/deploy/residency_schedule/.env
            /home/deploy/residency_schedule_new/bin/residency_schedule eval \
              "ResidencySchedule.Release.migrate()"

            # Atomic swap
            mv /home/deploy/residency_schedule /home/deploy/residency_schedule_old || true
            mv /home/deploy/residency_schedule_new /home/deploy/residency_schedule

            # Restart service (requires deploy user to have sudo on this one command)
            sudo systemctl restart residency_schedule

            # Verify it came up
            sleep 3
            systemctl is-active residency_schedule || (
              mv /home/deploy/residency_schedule_old /home/deploy/residency_schedule
              sudo systemctl restart residency_schedule
              echo "Deploy failed — rolled back" && exit 1
            )

            rm -rf /home/deploy/residency_schedule_old
```

---

### Migration Task Module

The workflow calls `ResidencySchedule.Release.migrate()`. Add this module so
migrations can be run from a release without `mix`:

```elixir
# lib/residency_schedule/release.ex
defmodule ResidencySchedule.Release do
  @app :residency_schedule

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
```

---

### GitHub Secrets Required

Set these in the repo under **Settings → Secrets and variables → Actions:**

| Secret | Value |
|---|---|
| `DEPLOY_HOST` | Droplet IP or domain, e.g. `123.45.67.89` |
| `DEPLOY_SSH_KEY` | Private SSH key for the `deploy` user (the full PEM) |
| `SECRET_KEY_BASE` | Output of `mix phx.gen.secret` |
| `PHX_HOST` | Your domain, e.g. `schedule.yourprogram.com` |

Note: `DATABASE_URL` and `ACCESS_PASSWORD` are **not** in GitHub Secrets — they
live only in `/home/deploy/residency_schedule/.env` on the server and are never
sent through GitHub. This limits secret exposure in the CI environment.

---

### Rollback Strategy

The deploy script keeps `residency_schedule_old` on the server until the new
release is confirmed healthy. If `systemctl is-active` fails, it automatically
swaps back and restarts the old release.

For a manual rollback at any time:
```bash
ssh deploy@your-droplet
mv /home/deploy/residency_schedule /home/deploy/residency_schedule_bad
mv /home/deploy/residency_schedule_old /home/deploy/residency_schedule
sudo systemctl restart residency_schedule
```

---

## Implementation Order

1. `mix phx.new residency_schedule --database postgres`
2. Add `nimble_csv` to deps; `mix deps.get`
3. Run migrations (schedules → residents → rotations)
4. `Schedule`, `Resident`, `Rotation` Ecto schemas
5. `Schedules`, `Residents`, `Rotations` contexts
6. `CsvParser` with unit tests using the actual CSV as a fixture
7. `ScheduleImporter`
8. **Auth:** `RequireAuth` plug + `AuthController` + login template
9. `UploadLive.Index`
10. `ScheduleLive.Index` (Gantt grid + year picker)
11. `ResidentLive.Show` (single resident timeline)
12. **iCal:** `Ical` module + `IcalController` + subscribe button on resident view
13. **Calendar:** `CalendarLive.Index` (monthly grid + hover day modal)
14. **Compare:** `CompareLive.Index` (dual dropdowns + co-service day count)
15. Add `ResidencySchedule.Release` migration task module
16. Configure `config/runtime.exs` for prod env vars
17. **CI/CD:** Add `.github/workflows/deploy.yml`
18. Provision Digital Ocean droplet, configure Nginx + systemd + `.env`
19. Set GitHub Secrets, push to `main`, verify first deployment
20. Filtering controls and visual polish

---

## Edge Cases (Confirmed from Real Data)

| Issue | Source | Fix |
|---|---|---|
| Dates Jan–Jun show year `2023` but should be `2024` | All rows | `fix_year_rollover/1` in parser |
| Trailing spaces in names | Several residents | `String.trim/1` on col B |
| Backtick `` ` `` cell value in R2-1 | Row 22 | Collect as warning, skip cell |
| Event annotation row (Retreat/CREOGS/Research Day) | Row 2 | Filtered by position_code regex |
| Separator rows between year groups | Rows 10, 19, 27, 36 | Filtered by position_code regex |
| Legend/summary table in last 2 rows | Rows 37–38 | Filtered by position_code regex |
| Empty trailing columns in date rows | Rows 0–1 | Filtered before date parse |
| Only 7 R4 residents (not 8) | R4 group | Schedule_number derived from data, not assumed |
| `AWAY` qualifier on elective slots (R3-2) | Row 11 | Mapped to `:away_rotation` |
| `USN` — meaning TBD | R1 residents only | Stored as `:unknown`, displayed as "Unknown" |
| `FLOAT` appears as pair at section boundaries | All years | Mapped to `:float` |
