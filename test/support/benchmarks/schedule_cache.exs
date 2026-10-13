# Run only against a disposable database created by the runner:
# SCHEDULE_BENCHMARK_DATABASE=residency_schedule_cache_bench_<suffix> \
#   MIX_ENV=test mix run --no-start test/support/benchmarks/schedule_cache.exs
# Drop that database after completion, including after a failed run.
database = System.fetch_env!("SCHEDULE_BENCHMARK_DATABASE")

unless Regex.match?(~r/^residency_schedule_cache_bench_[a-z0-9_]+$/, database),
  do: raise("benchmark requires an explicitly named disposable database")

repo_options =
  Application.fetch_env!(:residency_schedule, ResidencySchedule.Repo)
  |> Keyword.put(:database, database)
  |> Keyword.put(:pool, DBConnection.ConnectionPool)

Application.put_env(:residency_schedule, ResidencySchedule.Repo, repo_options)
Application.put_env(:residency_schedule, :current_date, ~D[2026-10-13])
{:ok, _} = Application.ensure_all_started(:residency_schedule)
Ecto.Migrator.run(ResidencySchedule.Repo, "priv/repo/migrations", :up, all: true)
Logger.configure(level: :warning)
Application.put_env(:residency_schedule, :chat, enabled: false)

{:ok, _, _} =
  File.read!("priv/demo/demo_schedule.csv")
  |> ResidencySchedule.Importer.ScheduleImporter.import_csv()

for year <- 2023..2025 do
  csv =
    Regex.replace(~r/202[67]/, File.read!("priv/demo/demo_schedule.csv"), fn digits ->
      Integer.to_string(String.to_integer(digits) + year - 2026)
    end)

  {:ok, _, _} = ResidencySchedule.Importer.ScheduleImporter.import_csv(csv)
end

schedule = Enum.find(ResidencySchedule.Schedules.list_schedules(), &(&1.academic_year == 2026))

batch =
  ResidencySchedule.Repo.insert!(%ResidencySchedule.DetailedSchedules.ImportBatch{
    schedule_id: schedule.id,
    fingerprint: "synthetic-performance-probe",
    header_start: ~D[2026-07-01],
    header_end: ~D[2027-06-30]
  })

now = DateTime.utc_now() |> DateTime.truncate(:second)
residents = ResidencySchedule.Residents.list_residents_across_schedules([schedule.id])

activities =
  for sr <- residents,
      date <- Date.range(~D[2026-07-01], ~D[2027-06-30]),
      do: %{
        schedule_resident_id: sr.id,
        date: date,
        raw_task: "Synthetic Clinic",
        inserted_at: now,
        updated_at: now
      }

activity_rows =
  activities
  |> Enum.chunk_every(3000)
  |> Enum.flat_map(fn chunk ->
    {_, rows} =
      ResidencySchedule.Repo.insert_all(ResidencySchedule.DetailedSchedules.Activity, chunk,
        returning: [:id]
      )

    rows
  end)

activity_rows
|> Enum.map(fn row ->
  %{
    activity_id: row.id,
    batch_id: batch.id,
    source_sheet: "Synthetic",
    source_cell: "A#{row.id}",
    raw_staff: "Synthetic Person",
    display_name: "Synthetic Person",
    previous_name: "Synthetic Person",
    notes: [],
    inserted_at: now,
    updated_at: now
  }
end)
|> Enum.chunk_every(3000)
|> Enum.each(
  &ResidencySchedule.Repo.insert_all(ResidencySchedule.DetailedSchedules.ActivitySource, &1)
)

IO.puts(Jason.encode!(%{synthetic_activities: length(activity_rows)}))

defmodule LatencyProbe do
  def event(_, measures, _, _) do
    :ets.update_counter(:latency_probe_queries, :count, {2, 1}, {:count, 0})

    for key <- [:total_time, :query_time, :decode_time, :queue_time] do
      :ets.update_counter(:latency_probe_queries, key, {2, measures[key] || 0}, {key, 0})
    end
  end

  def measure(label, fun) do
    :ets.delete_all_objects(:latency_probe_queries)
    {us, result} = :timer.tc(fun)

    queries =
      :ets.tab2list(:latency_probe_queries)
      |> Map.new(fn {k, v} ->
        {k, if(k == :count, do: v, else: v / System.convert_time_unit(1, :millisecond, :native))}
      end)

    IO.puts(Jason.encode!(%{phase: label, wall_ms: us / 1000, db: queries}))
    result
  end
end

:ets.new(:latency_probe_queries, [:named_table, :public, :set, write_concurrency: true])

:telemetry.attach(
  :latency_probe,
  [:residency_schedule, :repo, :query],
  &LatencyProbe.event/4,
  nil
)

schedules = ResidencySchedule.Schedules.list_schedules()

IO.puts(
  Jason.encode!(%{
    fixture: "four academic years plus detailed current-year daily assignments",
    schedules: length(schedules),
    residents:
      ResidencySchedule.Repo.aggregate(ResidencySchedule.Residents.ScheduleResident, :count),
    rotations: ResidencySchedule.Repo.aggregate(ResidencySchedule.Rotations.Rotation, :count)
  })
)

try do
  # Explicit transactions bypass the shared cache. Compare identical database
  # rows; timestamps and generated identities differ across independent seeds.
  {:ok, reference} =
    ResidencySchedule.Repo.transaction(fn ->
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_user: %ResidencySchedule.Accounts.User{role: :resident, tour_completed: true}
        }
      }

      {:ok, mounted} = ResidencyScheduleWeb.ScheduleLive.Index.mount(%{}, %{}, socket)

      html =
        ResidencyScheduleWeb.ScheduleLive.Index.render(mounted.assigns)
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      {{mounted.assigns.all_slots, mounted.assigns.unified_residents}, html}
    end)

  {slots, rows} = elem(reference, 0)

  expected_cells =
    Enum.map(rows, &ResidencySchedule.ScheduleCellReference.groups(slots, &1.rotation_lookup))

  for {label, builder} <- [
        {"reference", &ResidencySchedule.ScheduleCellReference.groups/2},
        {"current", &ResidencyScheduleWeb.ScheduleLive.Index.cell_groups_unified/2}
      ],
      run <- 1..5 do
    {:reductions, before_reductions} = Process.info(self(), :reductions)

    {microseconds, cells} =
      :timer.tc(fn -> Enum.map(rows, &builder.(slots, &1.rotation_lookup)) end)

    {:reductions, after_reductions} = Process.info(self(), :reductions)
    unless cells == expected_cells, do: raise("cell builder changed annotated output")

    IO.puts(
      Jason.encode!(%{
        phase: "schedule.cells.#{label}.#{run}",
        wall_ms: microseconds / 1000,
        reductions: after_reductions - before_reductions,
        rows: length(rows),
        slots: length(slots),
        exact_reference_match: true
      })
    )
  end

  outputs =
    for run <- 1..5 do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_user: %ResidencySchedule.Accounts.User{role: :resident, tour_completed: true}
        }
      }

      {:ok, mounted} =
        LatencyProbe.measure("schedule.mount.#{run}", fn ->
          ResidencyScheduleWeb.ScheduleLive.Index.mount(%{}, %{}, socket)
        end)

      html =
        LatencyProbe.measure("schedule.render_html.#{run}", fn ->
          ResidencyScheduleWeb.ScheduleLive.Index.render(mounted.assigns)
          |> Phoenix.HTML.Safe.to_iodata()
          |> IO.iodata_to_binary()
        end)

      grid = {mounted.assigns.all_slots, mounted.assigns.unified_residents}

      IO.puts(
        Jason.encode!(%{
          run: run,
          slot_count: length(mounted.assigns.all_slots),
          row_count: length(mounted.assigns.unified_residents),
          cell_count: Enum.sum(Enum.map(mounted.assigns.unified_residents, &length(&1.cells))),
          html_bytes: byte_size(html),
          grid_sha256: Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(grid))),
          html_sha256: Base.encode16(:crypto.hash(:sha256, html))
        })
      )

      {grid, html}
    end

  IO.puts(
    Jason.encode!(%{repeated_grid_and_html_equal: Enum.all?(outputs, &(&1 == hd(outputs)))})
  )

  equal_to_reference = Enum.all?(outputs, &(&1 == reference))
  IO.puts(Jason.encode!(%{cached_grid_and_html_equal_uncached_reference: equal_to_reference}))
  unless equal_to_reference, do: raise("cached output differs from uncached same-data reference")
after
  :telemetry.detach(:latency_probe)
end
