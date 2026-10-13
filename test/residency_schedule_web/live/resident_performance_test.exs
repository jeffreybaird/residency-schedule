defmodule ResidencyScheduleWeb.ResidentPerformanceTest do
  use ResidencyScheduleWeb.ConnCase, async: false

  alias Phoenix.LiveView.Socket

  alias ResidencySchedule.{
    ResidentDisplayNames,
    ResidentPerformanceFixtures,
    Residents,
    Rotations,
    ScheduleFixtures
  }

  alias ResidencyScheduleWeb.ResidentLive.Show

  setup do
    previous = Application.get_env(:residency_schedule, :current_date)
    Application.put_env(:residency_schedule, :current_date, ~D[2026-07-05])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:residency_schedule, :current_date, previous),
        else: Application.delete_env(:residency_schedule, :current_date)
    end)

    :ok
  end

  test "all four career years retain exact legacy entry maps and statistics without truncation" do
    appearances = ResidentPerformanceFixtures.four_year_career()
    selected = List.last(appearances)

    expected =
      appearances
      |> Enum.flat_map(fn resident ->
        Rotations.effective_segments_for_resident(resident.id)
        |> Enum.map(
          &Map.merge(&1, %{
            specific_tasks: [],
            specific_notes: [],
            schedule_id: resident.schedule_id,
            academic_year: resident.schedule.academic_year,
            schedule_label: resident.schedule.label
          })
        )
      end)
      |> ResidentDisplayNames.apply_to_entries()
      |> Enum.sort_by(& &1.start_date, Date)

    {:ok, socket} = mount(selected)
    assert socket.assigns.all_entries == expected
    assert socket.assigns.filtered_entries == expected
    assert length(socket.assigns.year_history) == 4

    assert socket.assigns.resident.rotations ==
             Rotations.projected_rotations_for_resident(selected.id)

    assert socket.assigns.total_shifts == 56
    assert socket.assigns.shifts_remaining == 10
    assert socket.assigns.night_shifts_remaining_strong == 7
    assert socket.assigns.night_shifts_remaining_highland == 0
    assert socket.assigns.schedule_start == ~D[2023-07-01]
    assert socket.assigns.schedule_end == ~D[2026-07-21]
    assert socket.assigns.coworkers == []
    assert socket.assigns.coworkers_loaded? == false
  end

  test "coworkers load only on the first tab visit and retain exact shared-day results" do
    data = ScheduleFixtures.seed_mini_schedule()

    expected =
      Rotations.list_coworker_shared_shift_counts(data.clare.id)
      |> ResidentDisplayNames.apply_to_entries()

    assert expected != []
    {:ok, socket} = mount(data.clare)
    assert socket.assigns.coworkers == []
    {:noreply, loaded} = Show.handle_event("switch_tab", %{"tab" => "coworkers"}, socket)
    assert loaded.assigns.coworkers == expected
    assert loaded.assigns.coworkers_loaded? == true
    assert_repeat_without_queries(loaded)
  end

  test "empty coworkers results are remembered rather than recomputed on each visit" do
    [resident | _] = ResidentPerformanceFixtures.four_year_career()
    {:ok, socket} = mount(resident)
    {:noreply, loaded} = Show.handle_event("switch_tab", %{"tab" => "coworkers"}, socket)
    assert loaded.assigns.coworkers == []
    assert loaded.assigns.coworkers_loaded? == true
    assert_repeat_without_queries(loaded)
  end

  defp mount(resident) do
    resident = Residents.get_resident!(resident.id)

    Show.mount(%{"id" => to_string(resident.id)}, %{}, %Socket{
      assigns: %{__changed__: %{}, current_user: nil}
    })
  end

  defp assert_repeat_without_queries(socket) do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:residency_schedule, :repo, :query],
      fn _, _, _, _ -> send(owner, :unexpected_coworker_query) end,
      nil
    )

    try do
      {:noreply, schedule} = Show.handle_event("switch_tab", %{"tab" => "schedule"}, socket)
      {:noreply, repeated} = Show.handle_event("switch_tab", %{"tab" => "coworkers"}, schedule)
      assert repeated.assigns.coworkers == socket.assigns.coworkers
      refute_received :unexpected_coworker_query
    after
      :telemetry.detach(handler)
    end
  end
end
