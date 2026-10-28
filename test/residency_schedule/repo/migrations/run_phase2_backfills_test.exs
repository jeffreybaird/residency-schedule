defmodule ResidencySchedule.Repo.Migrations.RunPhase2BackfillsTest do
  use ResidencySchedule.DataCase

  import ExUnit.CaptureLog

  alias ResidencySchedule.Repo.Migrations.RunPhase2Backfills
  alias ResidencySchedule.TimingDoctestFixtures

  # The migration is compiled onto the code path once by test/test_helper.exs
  # (ResidencySchedule.MigrationDoctests), never per test file.
  @migration "priv/repo/migrations/20261028190000_run_phase2_backfills.exs"

  # Tables the four Phase 2 backfills write, in pipeline order. Source
  # provenance updates columns on detailed_activity_sources; the others insert.
  @backfill_tables [
    "detailed_activity_sources",
    "source_identity_mappings",
    "activity_types",
    "source_task_mappings",
    "source_task_mapping_targets",
    "activity_source_classifications",
    "activity_source_timings"
  ]

  @legacy_tables [
    "schedules",
    "residents",
    "schedule_residents",
    "detailed_import_batches",
    "detailed_activities",
    "detailed_activity_sources"
  ]

  # Resident identifiers present in the fixture that must never reach the log.
  @fixture_names ["Iris Reed", "Reed, Iris", "Legacy Iris"]

  describe "migration attributes" do
    test "the migration has the fixed file name and module" do
      assert File.exists?(@migration)
      assert Code.ensure_loaded?(RunPhase2Backfills)
      assert function_exported?(RunPhase2Backfills, :run, 0)
      assert function_exported?(RunPhase2Backfills, :up, 0)
      assert function_exported?(RunPhase2Backfills, :down, 0)
    end

    test "the backfills run outside the migration transaction and lock" do
      attributes = RunPhase2Backfills.__migration__()

      assert Keyword.keyword?(attributes)
      assert Keyword.fetch!(attributes, :disable_ddl_transaction) == true
      assert Keyword.fetch!(attributes, :disable_migration_lock) == true
    end
  end

  describe "run/0" do
    test "executes the four backfills once over a seeded QGenda source" do
      ctx = TimingDoctestFixtures.source()

      assert {:ok, result} = RunPhase2Backfills.run()

      assert Enum.sort(Map.keys(result)) ==
               [:identity_mappings, :source_provenance, :task_classifications, :timings]

      # The fixture already stores its worksheet reference, so nothing is filled.
      assert result.source_provenance == %{activity_sources_updated: 0}

      assert result.identity_mappings ==
               %{observations_added: 1, unchanged: 0, conflicting_keys: 0}

      assert %{seed: seed, classifications: classifications} = result.task_classifications
      assert Enum.sort(Map.keys(result.task_classifications)) == [:classifications, :seed]
      assert seed.mappings_added > 0
      assert seed.conflicting == 0

      assert %{processed: 1, resolved: 1, unchanged: 0, conflicting: 0} = classifications

      assert result.timings ==
               %{processed: 1, period: 1, date_only: 0, unchanged: 0, conflicting: 0}

      assert [[1]] = count_where("source_identity_mappings", "evidence_source_id", ctx.source.id)

      assert [[1]] =
               count_where("activity_source_classifications", "original_source_id", ctx.source.id)

      assert [[1]] = count_where("activity_source_timings", "original_source_id", ctx.source.id)
    end

    test "fills an empty QGenda source reference before the later steps" do
      ctx = TimingDoctestFixtures.source()

      Repo.query!(
        "UPDATE detailed_activity_sources SET source_reference = '{}'::jsonb WHERE id = $1",
        [
          ctx.source.id
        ]
      )

      assert {:ok, result} = RunPhase2Backfills.run()
      assert result.source_provenance == %{activity_sources_updated: 1}

      assert [[%{"sheet" => "December", "cell" => cell}]] =
               Repo.query!(
                 "SELECT source_reference FROM detailed_activity_sources WHERE id = $1",
                 [ctx.source.id]
               ).rows

      assert cell == ctx.source.source_cell
      assert result.timings.processed == 1
    end

    test "repeating the run adds no rows and preserves every backfilled row" do
      _ctx = TimingDoctestFixtures.source()
      assert {:ok, _first} = RunPhase2Backfills.run()
      before = rows(@backfill_tables)

      assert {:ok, repeat} = RunPhase2Backfills.run()

      assert repeat.source_provenance == %{activity_sources_updated: 0}

      assert repeat.identity_mappings ==
               %{observations_added: 0, unchanged: 1, conflicting_keys: 0}

      assert repeat.task_classifications.seed.mappings_added == 0
      assert repeat.task_classifications.seed.conflicting == 0

      assert %{processed: 0, unchanged: 1, conflicting: 0} =
               repeat.task_classifications.classifications

      assert repeat.timings ==
               %{processed: 0, period: 0, date_only: 0, unchanged: 1, conflicting: 0}

      assert rows(@backfill_tables) == before
    end

    test "stops at the first failing step and retains the completed earlier steps" do
      ctx = add_custom_batch(TimingDoctestFixtures.source())
      legacy_before = rows(@legacy_tables)

      # Task classification is the first step that rejects a batch outside the
      # csv/qgenda namespaces, so timings never run. The failing page is rolled
      # back, which removes the fixture's own classification too.
      assert {:error, {:task_classifications, :unsupported_namespace}} =
               RunPhase2Backfills.run()

      assert [[1]] = count_where("source_identity_mappings", "evidence_source_id", ctx.source.id)
      assert [[0]] = count_all("activity_source_classifications")
      assert [[0]] = count_all("activity_source_timings")
      assert rows(@legacy_tables) == legacy_before
    end
  end

  describe "up/0 with the backfill flag on" do
    setup do
      set_backfill_flag(true)
    end

    test "runs the backfills without raising when every step succeeds" do
      ctx = TimingDoctestFixtures.source()

      RunPhase2Backfills.up()

      assert [[1]] = count_where("activity_source_timings", "original_source_id", ctx.source.id)
    end

    test "raises when a step fails so the deployment migration stops" do
      _ctx = add_custom_batch(TimingDoctestFixtures.source())

      raised =
        try do
          RunPhase2Backfills.up()
          nil
        rescue
          exception -> exception
        end

      assert is_exception(raised), "expected up/0 to raise, got #{inspect(raised)}"

      # A missing migration module raises too; that is not the contract.
      refute match?(%UndefinedFunctionError{}, raised)

      for name <- @fixture_names do
        refute Exception.message(raised) =~ name
      end
    end
  end

  describe "up/0 with the backfill flag off" do
    setup do
      set_backfill_flag(false)
      raise_log_level()
    end

    test "returns :ok, runs no backfill step and logs nothing private" do
      ctx = TimingDoctestFixtures.source()

      Repo.query!(
        "UPDATE detailed_activity_sources SET source_reference = '{}'::jsonb WHERE id = $1",
        [ctx.source.id]
      )

      log = capture_log(fn -> assert RunPhase2Backfills.up() == :ok end)

      for table <- [
            "source_identity_mappings",
            "source_task_mappings",
            "activity_source_classifications",
            "activity_source_timings"
          ] do
        assert [[0]] = count_all(table), "expected #{table} to stay empty"
      end

      assert [[reference]] =
               Repo.query!(
                 "SELECT source_reference FROM detailed_activity_sources WHERE id = $1",
                 [ctx.source.id]
               ).rows

      assert reference == %{}

      for name <- @fixture_names, do: refute(log =~ name)
    end
  end

  describe "down/0" do
    test "is a no-op that retains every backfilled row" do
      _ctx = TimingDoctestFixtures.source()
      assert {:ok, _result} = RunPhase2Backfills.run()
      before = rows(@backfill_tables ++ @legacy_tables)

      assert RunPhase2Backfills.down() == :ok

      assert rows(@backfill_tables ++ @legacy_tables) == before
    end
  end

  describe "logging" do
    setup do
      raise_log_level()
    end

    test "a successful run logs no resident name" do
      _ctx = TimingDoctestFixtures.source()

      log = capture_log(fn -> assert {:ok, _result} = RunPhase2Backfills.run() end)

      for name <- @fixture_names, do: refute(log =~ name)
    end

    test "a failed run logs no resident name" do
      _ctx = add_custom_batch(TimingDoctestFixtures.source())

      log = capture_log(fn -> assert {:error, _reason} = RunPhase2Backfills.run() end)

      for name <- @fixture_names, do: refute(log =~ name)
    end
  end

  # `up/0` honours this flag so test-suite migrations never seed the shared
  # database; `run/0` ignores it.
  defp set_backfill_flag(enabled) do
    key = :run_phase2_backfills_on_migrate
    previous = Application.fetch_env(:residency_schedule, key)
    Application.put_env(:residency_schedule, key, enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:residency_schedule, key, value)
        :error -> Application.delete_env(:residency_schedule, key)
      end
    end)

    :ok
  end

  defp raise_log_level do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  defp add_custom_batch(ctx) do
    TimingDoctestFixtures.add_source(ctx, source_kind: "custom", date: next_day(ctx))
    ctx
  end

  defp next_day(ctx), do: Date.add(ctx.activity.date, 1)

  defp count_all(table), do: Repo.query!("SELECT count(*) FROM #{table}").rows

  defp count_where(table, column, value) do
    Repo.query!("SELECT count(*) FROM #{table} WHERE #{column} = $1", [value]).rows
  end

  defp rows(tables) do
    Map.new(tables, fn table ->
      {table, Repo.query!("SELECT to_jsonb(t) FROM #{table} t ORDER BY to_jsonb(t)::text").rows}
    end)
  end
end
