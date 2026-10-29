# Run only in a disposable database created and dropped by the runner:
# SCHEDULE_BENCHMARK_DATABASE=residency_schedule_cache_bench_v2_<suffix> \
# MIX_ENV=test mix run --no-start test/support/benchmarks/effective_schedule_v2.exs
#
# Uses the schedule_cache benchmark's four demo years and one synthetic daily
# activity per current-year membership. The sole fixture adaptation is a unique
# synthetic staff alias per membership, so Phase 2 identity evidence can be
# explicitly approved instead of making every source ambiguous. All evidence
# writes finish before measurement. No comparison or resident-level data leaves
# memory; output contains fixed labels, aggregate counts and timings only.

unless Mix.env() == :test, do: raise("benchmark requires MIX_ENV=test")
database = System.fetch_env!("SCHEDULE_BENCHMARK_DATABASE")

unless Regex.match?(~r/^residency_schedule_cache_bench_v2_[a-z0-9_]+$/, database),
  do: raise("benchmark requires an explicitly named disposable v2 database")

repo_options =
  Application.fetch_env!(:residency_schedule, ResidencySchedule.Repo)
  |> Keyword.delete(:url)
  |> Keyword.put(:database, database)
  |> Keyword.put(:pool, DBConnection.ConnectionPool)

Application.put_env(:residency_schedule, ResidencySchedule.Repo, repo_options)
Application.put_env(:residency_schedule, :current_date, ~D[2026-10-13])
Application.put_env(:residency_schedule, :chat, enabled: false)
{:ok, _} = Application.ensure_all_started(:residency_schedule)

alias ResidencySchedule.{
  EffectiveSchedule,
  IdentityMappings,
  Repo,
  Residents,
  Rotations,
  Schedules,
  TaskMappings,
  Timings
}

alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}

unless Repo.query!("SELECT current_database()").rows == [[database]],
  do: raise("benchmark database preflight failed")

Logger.configure(level: :warning)
Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true)

csv = File.read!("priv/demo/demo_schedule.csv")

for year <- [2026, 2023, 2024, 2025] do
  shifted =
    Regex.replace(~r/202[67]/, csv, fn digits ->
      Integer.to_string(String.to_integer(digits) + year - 2026)
    end)

  {:ok, _, _} = ResidencySchedule.Importer.ScheduleImporter.import_csv(shifted)
end

schedule = Enum.find(Schedules.list_schedules(), &(&1.academic_year == 2026))
admin = ResidencySchedule.ScheduleFixtures.admin_user()

batch =
  Repo.insert!(%ImportBatch{
    schedule_id: schedule.id,
    created_by_id: admin.id,
    fingerprint: "synthetic-effective-read-probe",
    header_start: ~D[2026-07-01],
    header_end: ~D[2027-06-30]
  })

members = Residents.list_residents_for_schedule(schedule.id)
members_by_id = Map.new(members, &{&1.id, &1})
now = DateTime.utc_now(:second)

activity_rows =
  for member <- members, date <- Date.range(~D[2026-07-01], ~D[2027-06-30]) do
    %{
      schedule_resident_id: member.id,
      date: date,
      raw_task: "Synthetic Clinic",
      inserted_at: now,
      updated_at: now
    }
  end
  |> Enum.chunk_every(3000)
  |> Enum.flat_map(fn chunk ->
    {_, rows} = Repo.insert_all(Activity, chunk, returning: [:id, :schedule_resident_id])
    rows
  end)

activity_rows
|> Enum.map(fn row ->
  member = Map.fetch!(members_by_id, row.schedule_resident_id)

  %{
    activity_id: row.id,
    batch_id: batch.id,
    source_sheet: "Synthetic",
    source_cell: "A#{row.id}",
    raw_staff: "Benchmark alias #{member.id}",
    display_name: member.name,
    previous_name: member.name,
    notes: [],
    inserted_at: now,
    updated_at: now
  }
end)
|> Enum.chunk_every(3000)
|> Enum.each(&Repo.insert_all(ActivitySource, &1))

{:ok, _} = TaskMappings.seed_legacy()
{:ok, classifications} = TaskMappings.backfill()
{:ok, timings} = Timings.backfill()
{:ok, identities} = IdentityMappings.backfill()

crosswalk =
  Enum.map(
    members,
    &%{
      source_key: "Benchmark alias #{&1.id}",
      position_code: &1.position_code,
      expected_name: &1.name
    }
  )

{:ok, plan} = IdentityMappings.prepare_crosswalk(schedule.id, :qgenda, crosswalk, admin)
{:ok, approvals} = IdentityMappings.approve_crosswalk(plan, admin)

unless classifications.processed == length(activity_rows) and
         timings.processed == length(activity_rows) and
         identities.observations_added == length(activity_rows) and
         approvals.approved == length(members),
       do: raise("benchmark evidence setup is incomplete")

IO.puts(
  Jason.encode!(%{
    phase: "fixture",
    schedules: length(Schedules.list_schedules()),
    memberships: Repo.aggregate(ResidencySchedule.Residents.ScheduleResident, :count),
    rotations: Repo.aggregate(ResidencySchedule.Rotations.Rotation, :count),
    activities: length(activity_rows),
    classifications: classifications.processed,
    timings: timings.processed,
    observations: identities.observations_added,
    approvals: approvals.approved
  })
)

read = fn
  :legacy_projection ->
    Rotations.projected_rotations_for_schedule(schedule.id)

  version ->
    {:ok, records} = EffectiveSchedule.for_schedule(schedule.id, version)
    records
end

measure = fn version, phase, iteration ->
  :erlang.garbage_collect(self())
  {microseconds, count} = :timer.tc(fn -> read.(version) |> length() end)

  IO.puts(
    Jason.encode!(%{
      phase: phase,
      version: version,
      iteration: iteration,
      wall_ms: microseconds / 1000,
      result_count: count
    })
  )

  {version, microseconds}
end

versions = [:legacy_projection, :legacy, :v2]
# Initial calls are reported separately; no claim of OS/database cache eviction.
for version <- versions, do: measure.(version, "initial", 0)
for _ <- 1..2, version <- versions, do: read.(version)

measurements =
  for iteration <- 1..7, reduce: [] do
    results ->
      ordered = if rem(iteration, 2) == 1, do: versions, else: Enum.reverse(versions)
      results ++ Enum.map(ordered, &measure.(&1, "warm", iteration))
  end

medians =
  Map.new(versions, fn version ->
    samples =
      measurements
      |> Enum.filter(&(elem(&1, 0) == version))
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort()

    {version, Enum.at(samples, div(length(samples), 2))}
  end)

service_ratio = medians.v2 / max(medians.legacy, 1)
projection_ratio = medians.v2 / max(medians.legacy_projection, 1)

IO.puts(
  Jason.encode!(%{
    phase: "medians",
    iterations: 7,
    legacy_projection_ms: medians.legacy_projection / 1000,
    legacy_service_ms: medians.legacy / 1000,
    v2_service_ms: medians.v2 / 1000,
    v2_to_legacy_service: service_ratio,
    v2_to_legacy_projection: projection_ratio,
    maximum_ratio: 2.0
  })
)

unless service_ratio <= 2.0 and projection_ratio <= 2.0,
  do: raise("effective-read benchmark exceeds a 2x median performance gate")
