defmodule ResidencySchedule.ScheduleCacheIntegrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  alias Ecto.Adapters.SQL
  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents.{Resident, ScheduleResident}
  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.ScheduleCache
  alias ResidencySchedule.ScheduleCache.Revision
  alias ResidencySchedule.ScheduleEditor
  alias ResidencySchedule.Schedules.Schedule
  alias ResidencySchedule.ShiftOverrides
  alias ResidencySchedule.ShiftOverrides.ShiftOverride
  alias ResidencyScheduleWeb.ScheduleLive.Index

  setup do
    opts =
      Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 6)
      |> Keyword.put(:name, nil)

    repository = start_supervised!(Supervisor.child_spec({Repo, opts}, id: :cache_repository))
    previous = Repo.put_dynamic_repo(repository)

    on_exit(fn ->
      {:ok, cleanup_repo} = Repo.start_link(opts)
      Repo.put_dynamic_repo(cleanup_repo)

      try do
        cleanup_synthetic_rows()
      after
        Repo.put_dynamic_repo(previous)
        Supervisor.stop(cleanup_repo)
      end
    end)

    data = insert_graph()

    %{repository: repository, data: data}
  end

  test "same revision and date reuses data while date and committed writes invalidate", %{
    data: data
  } do
    today = ~D[2095-10-13]
    builder = fn -> Repo.get!(Resident, data.person.id).name end
    assert ScheduleCache.fetch(today, builder) == data.person.name
    assert ScheduleCache.fetch(today, fn -> flunk("warm cache rebuilt") end) == data.person.name
    assert ScheduleCache.fetch(Date.add(today, 1), fn -> :next_date end) == :next_date
    Repo.update!(Ecto.Changeset.change(data.person, name: "Renamed synthetic resident"))
    assert ScheduleCache.fetch(today, builder) == "Renamed synthetic resident"
  end

  test "all seven table writes advance committed revision and rollback preserves it", %{
    data: data
  } do
    rows = [
      data.schedule,
      data.person,
      data.member,
      data.rotation,
      data.override,
      data.activity,
      data.source
    ]

    for record <- rows do
      before = Revision.current()
      table = record.__struct__.__schema__(:source)

      SQL.query!(
        Repo.get_dynamic_repo(),
        "UPDATE #{table} SET updated_at = updated_at WHERE id = $1",
        [record.id]
      )

      assert Revision.current() > before, "missing update invalidation for #{table}"
    end

    before = Revision.current()

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               Repo.update!(Ecto.Changeset.change(data.person, name: "Never committed"))
               assert Revision.current() > before

               assert ScheduleCache.fetch(~D[2095-10-13], fn -> :transaction_local end) ==
                        :transaction_local

               Repo.rollback(:rollback)
             end)

    assert Revision.current() == before
    assert ScheduleCache.fetch(~D[2095-10-13], fn -> :committed end) == :committed
    assert Repo.get!(Resident, data.person.id).name == data.person.name
  end

  test "every inserted and deleted source record invalidates without context wrappers" do
    graph = insert_graph(true)
    remove_graph(graph, true)
  end

  test "an uncommitted writer cannot invalidate another connection until commit", %{
    repository: repo,
    data: data
  } do
    before = Revision.current()
    owner = self()

    writer =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.transaction(fn ->
          Repo.update!(Ecto.Changeset.change(data.person, name: "Committed later"))
          send(owner, :updated)

          receive do
            :commit -> :ok
          end
        end)
      end)

    assert_receive :updated
    assert Revision.current() == before
    send(writer.pid, :commit)
    assert {:ok, :ok} = Task.await(writer)
    assert Revision.current() > before
  end

  test "a build racing a committed write discards its stale value", %{
    repository: repo,
    data: data
  } do
    owner = self()

    task =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        ScheduleCache.fetch(~D[2095-10-14], fn ->
          name = Repo.get!(Resident, data.person.id).name

          unless Process.get(:cache_build_retried) do
            Process.put(:cache_build_retried, true)
            send(owner, :read_old_revision)

            receive do
              :continue -> :ok
            end
          end

          name
        end)
      end)

    assert_receive :read_old_revision
    Repo.update!(Ecto.Changeset.change(data.person, name: "Committed while building"))
    send(task.pid, :continue)
    assert Task.await(task) == "Committed while building"

    assert ScheduleCache.fetch(~D[2095-10-14], fn -> flunk("fresh result not cached") end) ==
             "Committed while building"
  end

  test "separate repository instances cannot share cached values", %{repository: repository} do
    assert ScheduleCache.fetch(~D[2095-10-15], fn -> :first_repository end) == :first_repository

    opts =
      Repo.config() |> Keyword.put(:pool, DBConnection.ConnectionPool) |> Keyword.put(:name, nil)

    other = start_supervised!(Supervisor.child_spec({Repo, opts}, id: :other_cache_repository))
    Repo.put_dynamic_repo(other)
    assert ScheduleCache.fetch(~D[2095-10-15], fn -> :other_repository end) == :other_repository
    Repo.put_dynamic_repo(repository)
  end

  test "continuous writes bound retries and fall back to one coherent snapshot", %{
    repository: repo,
    data: data
  } do
    calls = :atomics.new(1, [])

    {first, last} =
      ScheduleCache.fetch(~D[2095-10-16], fn ->
        count = :atomics.add_get(calls, 1, 1)
        assert count <= 5, "cache retry loop exceeded its bound"
        before = Repo.get!(Resident, data.person.id).name

        task =
          Task.async(fn ->
            Repo.put_dynamic_repo(repo)
            Repo.update!(Ecto.Changeset.change(data.person, name: "Revision #{count}"))
          end)

        Task.await(task)
        {before, Repo.get!(Resident, data.person.id).name}
      end)

    assert :atomics.get(calls, 1) > 1
    assert first == last
    assert ScheduleCache.fetch(~D[2095-10-16], fn -> :fresh_after_churn end) == :fresh_after_churn
  end

  test "real schedule mounts share prepared grid while retaining per-user state", %{data: data} do
    previous = Application.get_env(:residency_schedule, :current_date)
    Application.put_env(:residency_schedule, :current_date, ~D[2095-10-13])
    counter = projection_query_counter()

    try do
      {:ok, first} = mount(:resident)
      assert :atomics.get(counter, 1) > 0
      :atomics.put(counter, 1, 0)
      {:ok, second} = mount(:admin, self())
      assert :atomics.get(counter, 1) == 0
      assert first.assigns.unified_residents != []
      assert first.assigns.all_slots != []
      assert first.assigns.unified_residents == second.assigns.unified_residents
      assert first.assigns.all_slots == second.assigns.all_slots
      refute first.assigns.is_admin
      assert second.assigns.is_admin
      {:noreply, filtered} = Index.handle_event("filter_year", %{"year" => "1"}, first)
      assert filtered.assigns.filter_year == 1
      assert second.assigns.filter_year == nil
      # A changed roster must replace the cached immutable prepared result.
      Repo.update!(Ecto.Changeset.change(data.source, display_name: "Fresh imported identity"))
      {:ok, changed} = mount(:resident)
      assert Enum.any?(changed.assigns.unified_residents, &(&1.name == "Fresh imported identity"))
    after
      if previous,
        do: Application.put_env(:residency_schedule, :current_date, previous),
        else: Application.delete_env(:residency_schedule, :current_date)
    end
  end

  test "successful admin assignment and coverage edits invalidate warm cache; failed edits do not",
       %{data: data} do
    {:ok, _} = ShiftOverrides.delete_override(data.override.id)
    {:ok, state} = ScheduleEditor.load(data.schedule.id)
    today = ~D[2095-10-13]

    build = fn ->
      %{
        rotations:
          Repo.all(from(r in Rotation, where: r.schedule_resident_id == ^data.member.id)),
        overrides: ShiftOverrides.list_overrides_for_schedule(data.schedule.id)
      }
    end

    before = ScheduleCache.fetch(today, build)
    assert before.overrides == []
    assert Enum.any?(before.rotations, &(&1.rotation_type == "oncology"))

    assert {:error, _} =
             ScheduleEditor.commit(state, [
               %{
                 action: :update,
                 rotation_id: data.rotation.id,
                 attrs: %{
                   rotation_type: "invalid",
                   start_date: data.rotation.start_date,
                   end_date: data.rotation.end_date
                 }
               }
             ])

    assert ScheduleCache.fetch(today, fn -> flunk("failed edit invalidated cache") end) == before

    assert {:ok, _} =
             ScheduleEditor.commit(state, [
               %{
                 action: :update,
                 rotation_id: data.rotation.id,
                 attrs: %{
                   rotation_type: "elective",
                   start_date: data.rotation.start_date,
                   end_date: data.rotation.end_date
                 }
               }
             ])

    edited = ScheduleCache.fetch(today, build)
    assert Enum.any?(edited.rotations, &(&1.rotation_type == "elective"))
    assert {:error, _} = ShiftOverrides.create_override(%{})

    assert ScheduleCache.fetch(today, fn -> flunk("failed override invalidated cache") end) ==
             edited

    assert {:ok, override} =
             ShiftOverrides.create_override(%{
               rotation_id: data.rotation.id,
               covering_schedule_resident_id: data.member.id,
               override_start_date: data.rotation.start_date,
               override_end_date: data.rotation.end_date
             })

    covered = ScheduleCache.fetch(today, build)
    assert Enum.any?(covered.overrides, &(&1.id == override.id))
  end

  test "editor waits for revision before acquiring schedule rows", %{repository: repo, data: data} do
    {:ok, state} = ScheduleEditor.load(data.schedule.id)
    owner = self()

    blocker =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.transaction(fn ->
          Revision.lock()
          send(owner, :revision_locked)

          receive do
            :update -> :ok
          end

          Repo.update!(Ecto.Changeset.change(data.rotation, rotation_type: "ambulatory"))
        end)
      end)

    assert_receive :revision_locked

    editor =
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)

        Repo.checkout(fn ->
          %{rows: [[pid]]} = SQL.query!(Repo.get_dynamic_repo(), "SELECT pg_backend_pid()", [])
          send(owner, {:editor_backend, pid})

          ScheduleEditor.commit(state, [
            %{
              action: :update,
              rotation_id: data.rotation.id,
              attrs: %{
                rotation_type: "elective",
                start_date: data.rotation.start_date,
                end_date: data.rotation.end_date
              }
            }
          ])
        end)
      end)

    assert_receive {:editor_backend, backend}
    wait_for_lock(backend, System.monotonic_time(:millisecond) + 2000)
    send(blocker.pid, :update)
    assert {:ok, %Rotation{rotation_type: "ambulatory"}} = Task.await(blocker, 5000)

    assert {:error, "Schedule changed since it was loaded. Reload before saving."} =
             Task.await(editor, 5000)
  end

  defp mount(role, transport \\ nil) do
    socket = %Phoenix.LiveView.Socket{
      transport_pid: transport,
      assigns: %{
        __changed__: %{},
        current_user: %ResidencySchedule.Accounts.User{role: role, tour_completed: true}
      }
    }

    Index.mount(%{}, %{}, socket)
  end

  defp projection_query_counter do
    counter = :atomics.new(1, [])
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:residency_schedule, :repo, :query],
        fn _, _, metadata, _ ->
          if metadata[:source] in ["rotations", "detailed_activities"],
            do: :atomics.add(counter, 1, 1)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    counter
  end

  defp wait_for_lock(pid, deadline) do
    case SQL.query!(
           Repo.get_dynamic_repo(),
           "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
           [pid]
         ).rows do
      [["Lock"]] ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline, "editor never reached lock wait"
        wait_for_lock(pid, deadline)
    end
  end

  defp insert_graph(check_revision \\ false) do
    year = if check_revision, do: 2096, else: 2095

    schedule =
      insert!(%Schedule{academic_year: year, label: "Synthetic cache schedule"}, check_revision)

    person =
      insert!(
        %Resident{name: "Synthetic cache resident #{year}", calendar_token: Ecto.UUID.generate()},
        check_revision
      )

    member =
      insert!(
        %ScheduleResident{
          resident_id: person.id,
          schedule_id: schedule.id,
          position_code: "R1-1",
          residency_year: 1,
          schedule_number: 1
        },
        check_revision
      )

    rotation =
      insert!(
        %Rotation{
          schedule_resident_id: member.id,
          rotation_type: "oncology",
          start_date: ~D[2095-10-13],
          end_date: ~D[2095-10-19],
          slot_index: 0
        },
        check_revision
      )

    override =
      insert!(
        %ShiftOverride{
          rotation_id: rotation.id,
          covering_schedule_resident_id: member.id,
          override_start_date: rotation.start_date,
          override_end_date: rotation.end_date
        },
        check_revision
      )

    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: schedule.id,
        fingerprint: Ecto.UUID.generate(),
        header_start: rotation.start_date,
        header_end: rotation.end_date
      })

    activity =
      insert!(
        %Activity{
          schedule_resident_id: member.id,
          date: rotation.start_date,
          raw_task: "Synthetic clinic"
        },
        check_revision
      )

    source =
      insert!(
        %ActivitySource{
          activity_id: activity.id,
          batch_id: batch.id,
          source_sheet: "Synthetic",
          source_cell: "A1",
          raw_staff: person.name,
          display_name: person.name,
          previous_name: person.name,
          notes: []
        },
        check_revision
      )

    %{
      schedule: schedule,
      person: person,
      member: member,
      rotation: rotation,
      override: override,
      batch: batch,
      activity: activity,
      source: source
    }
  end

  defp insert!(row, check) do
    before = if check, do: Revision.current()
    result = Repo.insert!(row)
    if check, do: assert(Revision.current() > before, "missing insert invalidation")
    result
  end

  defp remove_graph(data, check) do
    for key <- [:source, :activity, :batch, :override, :rotation, :member, :person, :schedule] do
      row = Map.fetch!(data, key)
      before = if check, do: Revision.current()
      Repo.delete!(row)

      if check and key != :batch,
        do: assert(Revision.current() > before, "missing delete invalidation for #{key}")
    end
  end

  defp cleanup_synthetic_rows do
    # Only the dedicated synthetic years/label can be removed, including partial setup.
    people =
      SQL.query!(
        Repo.get_dynamic_repo(),
        "SELECT DISTINCT r.resident_id FROM schedule_residents r JOIN schedules s ON s.id=r.schedule_id WHERE s.academic_year IN (2095,2096) AND s.label='Synthetic cache schedule'",
        []
      ).rows
      |> List.flatten()

    SQL.query!(
      Repo.get_dynamic_repo(),
      "DELETE FROM detailed_activity_sources WHERE activity_id IN (SELECT a.id FROM detailed_activities a JOIN schedule_residents r ON r.id=a.schedule_resident_id JOIN schedules s ON s.id=r.schedule_id WHERE s.academic_year IN (2095,2096) AND s.label='Synthetic cache schedule')",
      []
    )

    SQL.query!(
      Repo.get_dynamic_repo(),
      "DELETE FROM detailed_activities WHERE schedule_resident_id IN (SELECT r.id FROM schedule_residents r JOIN schedules s ON s.id=r.schedule_id WHERE s.academic_year IN (2095,2096) AND s.label='Synthetic cache schedule')",
      []
    )

    SQL.query!(
      Repo.get_dynamic_repo(),
      "DELETE FROM detailed_import_batches WHERE schedule_id IN (SELECT id FROM schedules WHERE academic_year IN (2095,2096) AND label='Synthetic cache schedule')",
      []
    )

    SQL.query!(
      Repo.get_dynamic_repo(),
      "DELETE FROM schedules WHERE academic_year IN (2095,2096) AND label='Synthetic cache schedule'",
      []
    )

    SQL.query!(
      Repo.get_dynamic_repo(),
      "DELETE FROM residents WHERE id = ANY($1) AND NOT EXISTS (SELECT 1 FROM schedule_residents sr WHERE sr.resident_id=residents.id)",
      [people]
    )

    SQL.query!(
      Repo.get_dynamic_repo(),
      "DELETE FROM residents WHERE name LIKE 'Synthetic cache resident %' AND NOT EXISTS (SELECT 1 FROM schedule_residents sr WHERE sr.resident_id=residents.id)",
      []
    )
  end
end
