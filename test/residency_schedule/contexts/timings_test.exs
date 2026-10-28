defmodule ResidencySchedule.TimingsTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.DetailedSchedules.Activity
  alias ResidencySchedule.Release
  alias ResidencySchedule.TimingDoctestFixtures
  alias ResidencySchedule.Timings
  alias ResidencySchedule.Timings.{Backfill, Interpreter, Timing}

  @zone "America/New_York"
  @period_fields %{starts_at: nil, ends_at: nil, time_zone: nil, rule_version: "legacy_timing_v1"}
  @counts_keys [:conflicting, :date_only, :period, :processed, :unchanged]

  describe "interpret/1 happy paths" do
    test "a stored period label is recorded without establishing hours" do
      assert {:ok, result} = Timings.interpret(%{date: ~D[2026-12-30], period: "PM"})

      assert result ==
               Map.merge(@period_fields, %{
                 source_date: ~D[2026-12-30],
                 precision: :period,
                 period: "PM",
                 policy: "stored_period"
               })

      assert Interpreter.interpret(%{date: ~D[2026-12-30], period: "PM"}) == {:ok, result}
    end

    test "every label of the closed period set is accepted literally" do
      for period <- ["AM", "PM", "Day", "Night"] do
        assert {:ok, %{precision: :period, period: ^period, starts_at: nil, ends_at: nil}} =
                 Timings.interpret(%{date: ~D[2026-12-30], period: period})
      end
    end

    test "a night label keeps the literal source date and no next-morning end" do
      assert {:ok, result} = Timings.interpret(%{date: ~D[2026-12-31], period: "Night"})
      assert result.source_date == ~D[2026-12-31]
      assert result.period == "Night"
      assert result.starts_at == nil
      assert result.ends_at == nil
      assert result.time_zone == nil
    end

    test "a missing or nil period records only the date" do
      expected =
        Map.merge(@period_fields, %{
          source_date: ~D[2026-12-30],
          precision: :date_only,
          period: nil,
          policy: "date_only"
        })

      assert Timings.interpret(%{date: ~D[2026-12-30], period: nil}) == {:ok, expected}
      assert Timings.interpret(%{date: ~D[2026-12-30]}) == {:ok, expected}

      assert Timings.interpret(%{date: ~D[2026-12-30], period: nil, starts_at: nil, ends_at: nil}) ==
               {:ok, expected}

      assert Interpreter.interpret(%{date: ~D[2026-12-30]}) == {:ok, expected}
    end

    test "supplied instants in one zone are exact and keep the caller's literal date" do
      starts_at = DateTime.new!(~D[2026-12-30], ~T[07:00:00], @zone)
      ends_at = DateTime.new!(~D[2026-12-30], ~T[17:00:00], @zone)

      assert {:ok, result} =
               Timings.interpret(%{date: ~D[2026-12-30], starts_at: starts_at, ends_at: ends_at})

      assert result == %{
               source_date: ~D[2026-12-30],
               precision: :exact,
               period: nil,
               starts_at: starts_at,
               ends_at: ends_at,
               time_zone: @zone,
               rule_version: "legacy_timing_v1",
               policy: "exact_source"
             }

      assert Interpreter.interpret(%{
               date: ~D[2026-12-30],
               starts_at: starts_at,
               ends_at: ends_at
             }) ==
               {:ok, result}
    end

    test "exact timing never derives the source date from its instants" do
      starts_at = DateTime.new!(~D[2026-12-31], ~T[18:00:00], @zone)
      ends_at = DateTime.new!(~D[2027-01-01], ~T[07:00:00], @zone)

      assert {:ok, result} =
               Timings.interpret(%{
                 date: ~D[2026-12-30],
                 period: nil,
                 starts_at: starts_at,
                 ends_at: ends_at
               })

      assert result.source_date == ~D[2026-12-30]
      assert result.precision == :exact
      assert result.starts_at == starts_at
      assert result.ends_at == ends_at
      assert result.time_zone == @zone
    end
  end

  describe "interpret/1 errors" do
    test "a missing or invalid date is rejected before anything else" do
      for input <- [
            %{},
            %{period: "PM"},
            %{date: nil},
            %{date: nil, period: "PM"},
            %{date: "2026-12-30", period: "PM"},
            %{date: ~N[2026-12-30 07:00:00], period: "PM"},
            %{date: ~D[2026-12-30] |> Date.to_erl()}
          ] do
        assert {:error, :invalid_date} = Timings.interpret(input), inspect(input)
        assert {:error, :invalid_date} = Interpreter.interpret(input), inspect(input)
      end
    end

    test "a period outside the closed set is unsupported" do
      for period <- ["Evening", "pm", "AM ", "", "Nights", 12] do
        assert {:error, :unsupported_period} =
                 Timings.interpret(%{date: ~D[2026-12-30], period: period}),
               inspect(period)
      end
    end

    test "instants in different zones are rejected" do
      starts_at = DateTime.new!(~D[2026-12-30], ~T[07:00:00], @zone)
      ends_at = DateTime.new!(~D[2026-12-30], ~T[17:00:00], "America/Chicago")

      assert {:error, :invalid_instants} =
               Timings.interpret(%{date: ~D[2026-12-30], starts_at: starts_at, ends_at: ends_at})

      assert {:error, :invalid_instants} =
               Timings.interpret(%{
                 date: ~D[2026-12-30],
                 starts_at: starts_at,
                 ends_at: DateTime.shift_zone!(ends_at, "Etc/UTC")
               })
    end

    test "an end that is not after its start is rejected" do
      starts_at = DateTime.new!(~D[2026-12-30], ~T[07:00:00], @zone)

      assert {:error, :invalid_instants} =
               Timings.interpret(%{
                 date: ~D[2026-12-30],
                 starts_at: starts_at,
                 ends_at: starts_at
               })

      assert {:error, :invalid_instants} =
               Timings.interpret(%{
                 date: ~D[2026-12-30],
                 starts_at: starts_at,
                 ends_at: DateTime.add(starts_at, -1, :second)
               })
    end

    test "one instant without the other is rejected" do
      instant = DateTime.new!(~D[2026-12-30], ~T[07:00:00], @zone)

      assert {:error, :invalid_instants} =
               Timings.interpret(%{date: ~D[2026-12-30], starts_at: instant})

      assert {:error, :invalid_instants} =
               Timings.interpret(%{date: ~D[2026-12-30], ends_at: instant})

      assert {:error, :invalid_instants} =
               Timings.interpret(%{date: ~D[2026-12-30], starts_at: instant, ends_at: nil})

      assert {:error, :invalid_instants} =
               Timings.interpret(%{date: ~D[2026-12-30], starts_at: nil, ends_at: instant})
    end

    test "instants that are not DateTime values are rejected" do
      assert {:error, :invalid_instants} =
               Timings.interpret(%{
                 date: ~D[2026-12-30],
                 starts_at: ~N[2026-12-30 07:00:00],
                 ends_at: ~N[2026-12-30 17:00:00]
               })

      assert {:error, :invalid_instants} =
               Timings.interpret(%{
                 date: ~D[2026-12-30],
                 starts_at: "2026-12-30T07:00:00-05:00",
                 ends_at: "2026-12-30T17:00:00-05:00"
               })
    end

    test "instants together with a period are rejected" do
      starts_at = DateTime.new!(~D[2026-12-30], ~T[07:00:00], @zone)
      ends_at = DateTime.new!(~D[2026-12-30], ~T[17:00:00], @zone)

      assert {:error, :invalid_instants} =
               Timings.interpret(%{
                 date: ~D[2026-12-30],
                 period: "PM",
                 starts_at: starts_at,
                 ends_at: ends_at
               })

      assert {:error, :invalid_instants} =
               Interpreter.interpret(%{
                 date: ~D[2026-12-30],
                 period: "Night",
                 starts_at: starts_at,
                 ends_at: ends_at
               })
    end
  end

  describe "backfill/1 outcomes" do
    test "inserts one period or date-only row per saved source from stored facts only" do
      ctx = TimingDoctestFixtures.source()
      date_only = TimingDoctestFixtures.add_source(ctx, period: nil, date: next_day(ctx, 31))

      csv =
        TimingDoctestFixtures.add_source(ctx,
          period: "Night",
          raw_task: "NF",
          source_kind: "csv",
          date: Date.new!(ctx.schedule.academic_year + 1, 1, 1)
        )

      original = legacy_rows()

      assert {:ok, counts} = Timings.backfill()
      assert Enum.sort(Map.keys(counts)) == @counts_keys
      assert counts == %{processed: 3, period: 2, date_only: 1, unchanged: 0, conflicting: 0}
      assert legacy_rows() == original

      [pm_row, date_only_row, csv_row] = rows()

      assert pm_row["original_source_id"] == ctx.source.id
      assert pm_row["activity_source_id"] == ctx.source.id
      assert pm_row["namespace"] == "qgenda"
      assert pm_row["source_date"] == Date.to_iso8601(ctx.activity.date)
      assert pm_row["precision"] == "period"
      assert pm_row["period"] == "PM"
      assert pm_row["starts_at"] == nil
      assert pm_row["ends_at"] == nil
      assert pm_row["time_zone"] == nil
      assert pm_row["policy"] == "stored_period"
      assert pm_row["evidence_origin"] == "legacy_code"
      assert pm_row["rule_version"] == "legacy_timing_v1"
      assert is_binary(pm_row["input_digest"]) and pm_row["input_digest"] != ""

      assert pm_row["source_snapshot"] == %{
               "date" => Date.to_iso8601(ctx.activity.date),
               "raw_task" => "SMH GYN R2 Day",
               "period" => "PM"
             }

      assert date_only_row["original_source_id"] == date_only.source.id
      assert date_only_row["activity_source_id"] == date_only.source.id
      assert date_only_row["namespace"] == "qgenda"
      assert date_only_row["source_date"] == Date.to_iso8601(date_only.activity.date)
      assert date_only_row["precision"] == "date_only"
      assert date_only_row["period"] == nil
      assert date_only_row["starts_at"] == nil
      assert date_only_row["ends_at"] == nil
      assert date_only_row["time_zone"] == nil
      assert date_only_row["policy"] == "date_only"
      assert date_only_row["evidence_origin"] == "legacy_code"
      assert date_only_row["rule_version"] == "legacy_timing_v1"

      assert date_only_row["source_snapshot"] == %{
               "date" => Date.to_iso8601(date_only.activity.date),
               "raw_task" => "SMH GYN R2 Day",
               "period" => nil
             }

      assert csv_row["original_source_id"] == csv.source.id
      assert csv_row["namespace"] == "csv"
      assert csv_row["precision"] == "period"
      assert csv_row["period"] == "Night"
      assert csv_row["source_date"] == Date.to_iso8601(csv.activity.date)
      assert csv_row["source_snapshot"]["raw_task"] == "NF"
      assert csv_row["input_digest"] != pm_row["input_digest"]

      refute Enum.any?(rows(), &(&1["precision"] == "exact"))
    end

    test "the Timing schema reads saved rows with live and original references" do
      ctx = TimingDoctestFixtures.source("Day")
      assert {:ok, %{processed: 1, period: 1}} = Timings.backfill()

      timing = Repo.get_by!(Timing, original_source_id: ctx.source.id)
      assert timing.activity_source_id == ctx.source.id
      assert timing.namespace == "qgenda"
      assert timing.source_date == ctx.activity.date
      assert timing.precision == "period"
      assert timing.period == "Day"
      assert timing.starts_at == nil
      assert timing.ends_at == nil
      assert timing.time_zone == nil
      assert timing.policy == "stored_period"
      assert timing.rule_version == "legacy_timing_v1"
      assert timing.evidence_origin == "legacy_code"
      assert is_map(timing.source_snapshot)
      assert is_binary(timing.input_digest)
    end

    test "a completed repeat inserts zero rows and counts every row unchanged" do
      ctx = TimingDoctestFixtures.source()
      TimingDoctestFixtures.add_source(ctx, period: nil, date: next_day(ctx, 31))
      assert {:ok, %{processed: 2}} = Timings.backfill()
      saved = rows()
      original = legacy_rows()

      assert {:ok, repeated} = Timings.backfill()
      assert repeated == %{processed: 0, period: 0, date_only: 0, unchanged: 2, conflicting: 0}
      assert rows() == saved
      assert legacy_rows() == original

      assert {:ok, ^repeated} = Backfill.run(batch_size: 1)
      assert rows() == saved
    end

    test "a changed stored period after a row exists is conflicting and the row is retained" do
      ctx = TimingDoctestFixtures.source()
      assert {:ok, %{processed: 1}} = Timings.backfill()
      saved = rows()

      Repo.update_all(from(a in Activity, where: a.id == ^ctx.activity.id), set: [period: "AM"])

      assert {:ok, counts} = Timings.backfill()
      assert counts == %{processed: 0, period: 0, date_only: 0, unchanged: 0, conflicting: 1}
      assert rows() == saved
      assert Repo.get!(Activity, ctx.activity.id).period == "AM"
    end

    test "a stored period removed after a row exists is conflicting rather than reinterpreted" do
      ctx = TimingDoctestFixtures.source()
      assert {:ok, %{processed: 1}} = Timings.backfill()
      saved = rows()

      Repo.update_all(from(a in Activity, where: a.id == ^ctx.activity.id), set: [period: nil])

      assert {:ok, %{processed: 0, date_only: 0, unchanged: 0, conflicting: 1}} =
               Timings.backfill()

      assert rows() == saved
      assert hd(rows())["precision"] == "period"
    end

    test "a changed stored date after a row exists is conflicting and never adjusts the row" do
      ctx = TimingDoctestFixtures.source()
      assert {:ok, %{processed: 1}} = Timings.backfill()
      saved = rows()

      Repo.update_all(from(a in Activity, where: a.id == ^ctx.activity.id),
        set: [date: next_day(ctx, 31)]
      )

      assert {:ok, %{processed: 0, unchanged: 0, conflicting: 1}} = Timings.backfill()
      assert rows() == saved
      assert hd(rows())["source_date"] == Date.to_iso8601(ctx.activity.date)
    end

    test "a changed raw task after a row exists is conflicting because the snapshot differs" do
      ctx = TimingDoctestFixtures.source()
      assert {:ok, %{processed: 1}} = Timings.backfill()
      saved = rows()

      Repo.update_all(from(a in Activity, where: a.id == ^ctx.activity.id),
        set: [raw_task: "Vacation"]
      )

      assert {:ok, %{processed: 0, unchanged: 0, conflicting: 1}} = Timings.backfill()
      assert rows() == saved
    end

    test "a changed stored rule version after a row exists is conflicting and retained" do
      ctx = TimingDoctestFixtures.source()
      assert {:ok, %{processed: 1}} = Timings.backfill()

      Repo.query!(
        "UPDATE activity_source_timings SET rule_version='legacy_timing_v0' WHERE original_source_id=$1",
        [ctx.source.id]
      )

      saved = rows()
      assert {:ok, %{processed: 0, unchanged: 0, conflicting: 1}} = Timings.backfill()
      assert rows() == saved
    end

    test "reviewed and custom rows stay unchanged even when source facts move" do
      ctx = TimingDoctestFixtures.source()
      other = TimingDoctestFixtures.add_source(ctx, period: nil, date: next_day(ctx, 31))
      assert {:ok, %{processed: 2}} = Timings.backfill()

      Repo.query!(
        "UPDATE activity_source_timings SET evidence_origin='reviewed' WHERE original_source_id=$1",
        [ctx.source.id]
      )

      Repo.query!(
        "UPDATE activity_source_timings SET evidence_origin='custom' WHERE original_source_id=$1",
        [other.source.id]
      )

      saved = rows()

      Repo.update_all(from(a in Activity, where: a.id == ^ctx.activity.id), set: [period: "AM"])

      Repo.update_all(from(a in Activity, where: a.id == ^other.activity.id),
        set: [period: "Night"]
      )

      assert {:ok, %{processed: 0, unchanged: 2, conflicting: 0}} = Timings.backfill()
      assert rows() == saved
    end

    test "a live stored period outside the closed set receives no row and is conflicting" do
      ctx = TimingDoctestFixtures.source("Evening")
      TimingDoctestFixtures.add_source(ctx, period: "pm", date: next_day(ctx, 31))
      valid = TimingDoctestFixtures.add_source(ctx, period: "AM", date: next_day(ctx, 29))
      original = legacy_rows()

      assert {:ok, counts} = Timings.backfill()
      assert counts == %{processed: 1, period: 1, date_only: 0, unchanged: 0, conflicting: 2}
      assert [row] = rows()
      assert row["original_source_id"] == valid.source.id
      assert legacy_rows() == original

      assert {:ok, %{processed: 0, unchanged: 1, conflicting: 2}} = Timings.backfill()
      assert rows() == [row]
    end
  end

  describe "backfill/1 batches and errors" do
    test "invalid batch sizes and options are rejected without writing" do
      TimingDoctestFixtures.source()

      for options <- [
            [batch_size: 0],
            [batch_size: 1001],
            [batch_size: -1],
            [batch_size: "1"],
            [batch_size: nil],
            [unknown: 1],
            [batch_size: 1, unknown: 1],
            :bad,
            %{batch_size: 1}
          ] do
        assert {:error, :invalid_batch_size} = Timings.backfill(options), inspect(options)
        assert {:error, :invalid_batch_size} = Backfill.run(options), inspect(options)
      end

      assert rows() == []
    end

    test "the default and bounds of the batch size are accepted" do
      TimingDoctestFixtures.source()
      assert {:ok, %{processed: 1}} = Timings.backfill()
      assert {:ok, %{processed: 0, unchanged: 1}} = Timings.backfill([])
      assert {:ok, %{processed: 0, unchanged: 1}} = Timings.backfill(batch_size: 1)
      assert {:ok, %{processed: 0, unchanged: 1}} = Timings.backfill(batch_size: 500)
      assert {:ok, %{processed: 0, unchanged: 1}} = Timings.backfill(batch_size: 1000)
    end

    test "a batch size of one walks every source across batches by stable id" do
      ctx = TimingDoctestFixtures.source()
      second = TimingDoctestFixtures.add_source(ctx, period: nil, date: next_day(ctx, 31))
      third = TimingDoctestFixtures.add_source(ctx, period: "Night", date: next_day(ctx, 29))

      assert {:ok, counts} = Timings.backfill(batch_size: 1)
      assert counts == %{processed: 3, period: 2, date_only: 1, unchanged: 0, conflicting: 0}

      assert Enum.map(rows(), & &1["original_source_id"]) ==
               Enum.sort([ctx.source.id, second.source.id, third.source.id])

      assert {:ok, %{processed: 0, unchanged: 3}} = Timings.backfill(batch_size: 2)
    end

    test "a batch whose source kind is outside csv and qgenda is rolled back" do
      ctx = TimingDoctestFixtures.source()
      TimingDoctestFixtures.add_source(ctx, source_kind: "custom", date: next_day(ctx, 31))
      original = legacy_rows()

      assert {:error, :unsupported_namespace} = Timings.backfill()
      assert rows() == []
      assert legacy_rows() == original
    end

    test "earlier batches remain when a later batch has an unsupported source kind" do
      ctx = TimingDoctestFixtures.source()
      TimingDoctestFixtures.add_source(ctx, source_kind: "custom", date: next_day(ctx, 31))
      original = legacy_rows()

      assert {:error, :unsupported_namespace} = Timings.backfill(batch_size: 1)
      assert [saved] = rows()
      assert saved["original_source_id"] == ctx.source.id
      assert legacy_rows() == original

      assert {:error, :unsupported_namespace} = Backfill.run(batch_size: 1)
      assert rows() == [saved]
    end

    test "an empty source table completes with zero counts" do
      assert Timings.backfill() ==
               {:ok, %{processed: 0, period: 0, date_only: 0, unchanged: 0, conflicting: 0}}
    end
  end

  describe "retention and isolation" do
    test "source deletion releases the live reference while retaining original evidence" do
      ctx = TimingDoctestFixtures.source()
      assert {:ok, %{processed: 1}} = Timings.backfill()
      [before] = rows()

      Repo.delete!(ctx.source)

      [after_delete] = rows()
      assert after_delete["activity_source_id"] == nil
      assert after_delete["original_source_id"] == ctx.source.id
      assert after_delete["source_snapshot"] == before["source_snapshot"]

      assert Map.drop(after_delete, ["activity_source_id"]) ==
               Map.drop(before, ["activity_source_id"])

      Repo.delete!(ctx.batch)
      Repo.delete!(ctx.activity)
      assert {:ok, _} = ResidencySchedule.Schedules.delete_schedule(ctx.schedule.id)
      assert rows() == [after_delete]
    end

    test "the backfill never rewrites activities, sources, batches or rotations" do
      ctx = TimingDoctestFixtures.source("Night")
      TimingDoctestFixtures.add_source(ctx, period: nil, date: next_day(ctx, 31))

      {:ok, _} =
        ResidencySchedule.Rotations.insert_rotations(ctx.member.id, [
          %{
            slot_index: 0,
            start_date: Date.new!(ctx.schedule.academic_year, 12, 28),
            end_date: Date.new!(ctx.schedule.academic_year + 1, 1, 3),
            rotation_type: :strong_gynecology
          }
        ])

      original = legacy_rows()
      assert {:ok, %{processed: 2}} = Timings.backfill(batch_size: 1)
      assert legacy_rows() == original
      assert {:ok, %{processed: 0, unchanged: 2}} = Timings.backfill()
      assert legacy_rows() == original
    end

    test "the database rejects duplicate original evidence and inconsistent timing rows" do
      ctx = TimingDoctestFixtures.source()
      assert {:ok, %{processed: 1}} = Timings.backfill()
      [timing] = rows()

      assert_rejected(
        "INSERT INTO activity_source_timings (original_source_id, activity_source_id, namespace, source_date, precision, period, source_snapshot, input_digest, rule_version, policy, evidence_origin, inserted_at, updated_at) SELECT original_source_id, activity_source_id, namespace, source_date, precision, period, source_snapshot, input_digest, rule_version, policy, evidence_origin, inserted_at, updated_at FROM activity_source_timings WHERE id=$1",
        [timing["id"]]
      )

      assert_rejected("UPDATE activity_source_timings SET precision='exact' WHERE id=$1", [
        timing["id"]
      ])

      assert_rejected("UPDATE activity_source_timings SET period=NULL WHERE id=$1", [
        timing["id"]
      ])

      assert_rejected("UPDATE activity_source_timings SET period='Evening' WHERE id=$1", [
        timing["id"]
      ])

      assert_rejected(
        "UPDATE activity_source_timings SET starts_at=now(), ends_at=now() + interval '1 hour', time_zone='America/New_York' WHERE id=$1",
        [timing["id"]]
      )

      assert_rejected("UPDATE activity_source_timings SET namespace='other' WHERE id=$1", [
        timing["id"]
      ])

      assert_rejected("UPDATE activity_source_timings SET policy='guessed' WHERE id=$1", [
        timing["id"]
      ])

      assert_rejected("UPDATE activity_source_timings SET evidence_origin='bot' WHERE id=$1", [
        timing["id"]
      ])

      assert_rejected(
        "UPDATE activity_source_timings SET activity_source_id=original_source_id+1 WHERE id=$1",
        [timing["id"]]
      )

      assert rows() == [timing]
      assert Repo.get!(Activity, ctx.activity.id).period == "PM"
    end
  end

  describe "Release.backfill_timings/0" do
    test "the compiled release wrapper returns the backfill counts" do
      ctx = TimingDoctestFixtures.source()
      TimingDoctestFixtures.add_source(ctx, period: nil, date: next_day(ctx, 31))
      original = legacy_rows()

      assert Release.backfill_timings() ==
               {:ok, %{processed: 2, period: 1, date_only: 1, unchanged: 0, conflicting: 0}}

      assert Release.backfill_timings() ==
               {:ok, %{processed: 0, period: 0, date_only: 0, unchanged: 2, conflicting: 0}}

      assert length(rows()) == 2
      assert legacy_rows() == original
    end
  end

  defp next_day(ctx, day), do: Date.new!(ctx.schedule.academic_year, 12, day)

  defp rows do
    Repo.query!("SELECT to_jsonb(t) FROM activity_source_timings t ORDER BY id").rows
    |> Enum.map(&hd/1)
  end

  defp legacy_rows do
    Map.new(
      [
        "detailed_import_batches",
        "detailed_activities",
        "detailed_activity_sources",
        "rotations"
      ],
      &{&1, Repo.query!("SELECT to_jsonb(t) FROM #{&1} t ORDER BY id").rows}
    )
  end

  defp assert_rejected(sql, params) do
    assert_raise Postgrex.Error, fn -> Repo.query!(sql, params, mode: :savepoint) end
  end
end
