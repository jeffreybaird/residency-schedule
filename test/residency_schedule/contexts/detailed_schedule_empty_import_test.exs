defmodule ResidencySchedule.DetailedScheduleEmptyImportTest do
  use ResidencySchedule.DataCase
  alias ResidencySchedule.{DetailedSchedules, Repo, Schedules}
  alias ResidencySchedule.Importer.QgendaPreview

  test "a preview with no matched residents cannot create an empty protective batch" do
    {:ok, _} = Schedules.upsert_schedule(2026, "2026–2027")
    admin = ResidencySchedule.ScheduleFixtures.admin_user()

    {:ok, preview} =
      QgendaPreview.prepare(File.read!("test/fixtures/qgenda/shared.xlsx"), academic_year: 2026)

    assert Enum.all?(preview.assignments, &is_nil(&1.resident_id))
    before = counts()
    assert {:error, reason} = DetailedSchedules.commit(preview, admin)
    assert is_binary(reason)
    assert counts() == before
  end

  defp counts do
    for table <- ["detailed_import_batches", "detailed_activities", "detailed_activity_sources"],
        into: %{},
        do: {table, Repo.aggregate(table, :count, :id)}
  end
end
