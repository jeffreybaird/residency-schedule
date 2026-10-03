defmodule ResidencySchedule.DetailedScheduleIntegrityTest do
  use ResidencySchedule.DataCase
  import ResidencySchedule.QgendaDetailFixtures
  alias ResidencySchedule.{DetailedSchedules, Repo}

  setup do
    data = seed_detail_roster()
    {:ok, preview} = detail_preview()
    Map.merge(data, %{preview: preview, admin: ResidencySchedule.ScheduleFixtures.admin_user()})
  end

  test "conflicting incoming source coordinates roll back batch, activity and provenance", ctx do
    [first, second | rest] = ctx.preview.assignments
    refute {first.date, first.raw_task} == {second.date, second.raw_task}
    collision = %{second | source_sheet: first.source_sheet, source_cell: first.source_cell}
    preview = %{ctx.preview | assignments: [first, collision | rest]}
    before = detail_counts()
    assert {:error, _} = DetailedSchedules.commit(preview, ctx.admin)
    assert detail_counts() == before
    assert DetailedSchedules.list_for_date(ctx.schedule.id, first.date) == []
  end

  test "database prevents deleting a roster row referenced by saved activities", ctx do
    {:ok, _} = DetailedSchedules.commit(ctx.preview, ctx.admin)
    before = DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29])
    resident = Repo.get!(ResidencySchedule.Residents.ScheduleResident, ctx.iris.id)
    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(resident, mode: :savepoint) end
    assert Repo.get(ResidencySchedule.Residents.ScheduleResident, ctx.iris.id)
    assert DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29]) == before
  end

  defp detail_counts do
    for table <- ["detailed_import_batches", "detailed_activities", "detailed_activity_sources"],
        into: %{},
        do: {table, Repo.aggregate(table, :count, :id)}
  end
end
