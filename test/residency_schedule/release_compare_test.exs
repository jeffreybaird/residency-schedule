defmodule ResidencySchedule.ReleaseCompareTest do
  use ResidencySchedule.DataCase

  import ExUnit.CaptureIO

  alias ResidencySchedule.Release
  alias ResidencySchedule.ScheduleFixtures

  describe "compare_effective_schedule/1" do
    test "prints only aggregate counts and returns the full summary" do
      data = ScheduleFixtures.seed_mini_schedule()
      ScheduleFixtures.seed_prior_year_for_clare(data)
      schedule = data.schedule
      parent = self()

      output =
        capture_io(fn ->
          send(parent, {:result, Release.compare_effective_schedule(schedule.id)})
        end)

      assert_receive {:result, {:ok, summary}}
      assert summary.schedule_id == schedule.id
      assert summary.identical_days == 63
      assert summary.differing_days == 0
      assert summary.differing_calendar_events == 0
      assert summary.differing_consumer_outputs == 0
      assert summary.unresolved_evidence == 0
      assert summary.detail == %{days: [], calendar_events: [], evidence: []}

      lines = String.split(output, "\n", trim: true)
      assert length(lines) == 6

      assert output =~ "schedule_id: #{schedule.id}"
      assert output =~ "identical_days: 63"
      assert output =~ "differing_days: 0"
      assert output =~ "differing_calendar_events: 0"
      assert output =~ "differing_consumer_outputs: 0"
      assert output =~ "unresolved_evidence: 0"

      for name <- ~w(Clare Mary Tiff) do
        refute output =~ name
      end

      refute output =~ ~r/\d{4}-\d{2}-\d{2}/
      refute output =~ ~r/\d{8}T\d{6}/
      refute output =~ "detail"
      refute output =~ "person_id"
      refute output =~ "schedule_resident_id"
      refute output =~ "duties"
    end

    test "returns not found for an unknown schedule without printing counts" do
      parent = self()

      output =
        capture_io(fn ->
          send(parent, {:result, Release.compare_effective_schedule(-1)})
        end)

      assert_receive {:result, {:error, :not_found}}
      refute output =~ "identical_days"
    end

    test "unresolved evidence prints only numeric aggregates and remains in returned detail" do
      alias ResidencySchedule.EffectiveScheduleV2Fixtures, as: F
      member = F.member()
      source = F.source(member, ~D[2026-11-03], "PRIVATE RAW TASK")
      parent = self()

      output =
        capture_io(fn ->
          send(parent, {:result, Release.compare_effective_schedule(member.schedule_id)})
        end)

      assert_receive {:result, {:ok, summary}}
      assert summary.unresolved_evidence == 3
      assert F.diagnostic(source, :missing_identity) in summary.detail.evidence
      assert output =~ "unresolved_evidence: 3"

      assert Enum.all?(
               String.split(output, "\n", trim: true),
               &Regex.match?(~r/\A[a-z_]+: \d+\z/, &1)
             )

      refute output =~ ~r/(?:^|\n)(?:evidence|detail):/

      for private <- [
            member.name,
            source.activity.raw_task,
            "2026-11-03",
            "activity_source_id",
            "schedule_resident_id",
            "missing_identity",
            "ready"
          ] do
        refute output =~ private
      end
    end
  end
end
