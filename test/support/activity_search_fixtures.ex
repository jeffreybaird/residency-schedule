defmodule ResidencySchedule.ActivitySearchFixtures do
  @moduledoc "Synthetic, searchable activities with literal punctuation and note text."
  import ResidencySchedule.QgendaDetailFixtures
  alias ResidencySchedule.DetailedSchedules

  @doc "Seeds eight matched activities, including a note with literal search punctuation."
  def seed_activity_search do
    data = seed_detail_roster()
    admin = ResidencySchedule.ScheduleFixtures.admin_user()
    {:ok, preview} = detail_preview(search_workbook())
    {:ok, _} = DetailedSchedules.commit(preview, admin)
    Map.put(data, :admin, admin)
  end

  @doc """
  Returns the pseudonymized search workbook.

      iex> is_binary(ResidencySchedule.ActivitySearchFixtures.search_workbook())
      true
  """
  def search_workbook do
    mutate_detail_workbook("xl/sharedStrings.xml", fn xml ->
      String.replace(
        xml,
        "Bring simulation kit",
        "Bring simulation kit; 100% clinic_A C:\\Room; &lt;b&gt;literal&lt;/b&gt;"
      )
    end)
  end
end
