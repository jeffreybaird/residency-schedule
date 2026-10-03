defmodule ResidencySchedule.RotationSupportFixtures do
  @moduledoc false

  def pairs do
    [
      {"LOA", :leave_of_absence},
      {"ADMIN", :admin},
      {"ADMIN/MFM", :admin_mfm},
      {"COB", :cob},
      {"GOG/Colpo", :gog_colpo},
      {"MFM", :mfm},
      {"MFM/pain", :mfm_pain},
      {"MFM PM", :mfm_pm},
      {"Orient", :orientation},
      {"ONC (orient)", :oncology_orientation},
      {"HHOB (orient)", :highland_obstetrics_orientation},
      {"GYN (orient)", :strong_gynecology_orientation},
      {"HGYN (orient)", :highland_gynecology_orientation},
      {"OB (orient)", :strong_obstetrics_orientation}
    ]
  end

  def csv(labels) do
    dates = Enum.with_index(labels, fn _, index -> Date.add(~D[2026-07-06], index) end)
    header = Enum.map_join(dates, ",", &Date.to_iso8601/1)
    ",Dates,#{header}\n,,#{header}\n,,Events\nR4-1,Test Resident,#{Enum.join(labels, ",")}\n"
  end
end
