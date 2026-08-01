defmodule ResidencySchedule.Importer.NameNormalizer do
  @moduledoc """
  Maps raw resident names to canonical first-name forms.

  Names are keyed by {academic_year_start, position_code} because the same
  position code refers to a different person across years, and the same person
  may appear with different spellings or full names in different years.

  Residents with ambiguous first names keep a disambiguating suffix:
  Ally Z, Allie G, Emily K, Emily Y, Emily F, JD, Paige R, Paige K.

  ## Examples

    iex> forward_ok? =
    ...>   Enum.all?(@canonincal_names_to_schedule_numbers, fn {name, entries} ->
    ...>     Enum.all?(entries, fn {year, sched} ->
    ...>       Map.get(@canonical_names, {year, sched}) == name
    ...>     end)
    ...>   end)
    ...>
    iex> reverse_ok? =
    ...>   Enum.all?(@canonical_names, fn {{year, sched}, name} ->
    ...>     entries = Map.get(@canonincal_names_to_schedule_numbers, name, [])
    ...>     Enum.member?(entries, {year, sched})
    ...>   end)
    ...>
    iex> forward_ok? and reverse_ok?
    true
  """
  @canonincal_names_to_schedule_numbers %{
    # 2023 R4s — graduating, one year only
    "Alexis" => [{2023, "R4-1"}],
    "Emily" => [{2023, "R4-2"}],
    "Michelle" => [{2023, "R4-3"}],
    "Devin" => [{2023, "R4-4"}],
    "Joanna" => [{2023, "R4-5"}],
    "Yanling" => [{2023, "R4-6"}],
    "Victoria" => [{2023, "R4-7"}],
    # 2023 R3s → 2024 R4s
    "Kathryn" => [{2023, "R3-1"}, {2024, "R4-4"}],
    "Lila" => [{2023, "R3-2"}, {2024, "R4-1"}],
    "Tricia" => [{2023, "R3-3"}, {2024, "R4-3"}],
    "Leanne" => [{2023, "R3-4"}, {2024, "R4-7"}],
    "Savannah" => [{2023, "R3-5"}, {2024, "R4-2"}],
    "Pivi" => [{2023, "R3-6"}, {2024, "R4-8"}],
    "Aladeyemi" => [{2023, "R3-7"}, {2024, "R4-5"}],
    "Danielle" => [{2023, "R3-8"}, {2024, "R4-6"}],
    # 2023 R2s → 2024 R3s → 2025 R4s
    "Chima" => [{2023, "R2-1"}, {2024, "R3-8"}, {2025, "R4-6"}],
    "Laura" => [{2023, "R2-2"}, {2024, "R3-7"}, {2025, "R4-1"}],
    "Emily K" => [{2023, "R2-3"}, {2024, "R3-6"}, {2025, "R4-8"}],
    "Ally Z" => [{2023, "R2-4"}, {2024, "R3-1"}, {2025, "R4-7"}],
    "Annie" => [{2023, "R2-5"}, {2024, "R3-3"}, {2025, "R4-5"}],
    "Young" => [{2023, "R2-6"}, {2024, "R3-4"}, {2025, "R4-2"}],
    "Allie G" => [{2023, "R2-7"}, {2024, "R3-2"}, {2025, "R4-4"}],
    "Carolyn" => [{2023, "R2-8"}, {2024, "R3-5"}, {2025, "R4-3"}],
    # 2023 R1s → 2024 R2s → 2025 R3s → 2026 R4s
    "Carson" => [{2023, "R1-1"}, {2024, "R2-6"}, {2025, "R3-3"}, {2026, "R4-7"}],
    "Dana" => [{2023, "R1-2"}, {2024, "R2-3"}, {2025, "R3-2"}, {2026, "R4-4"}],
    "Grace" => [{2023, "R1-3"}, {2024, "R2-8"}, {2025, "R3-8"}, {2026, "R4-2"}],
    "Clare" => [{2023, "R1-4"}, {2024, "R2-2"}, {2025, "R3-1"}, {2026, "R4-6"}],
    "Emily Y" => [{2023, "R1-5"}, {2024, "R2-1"}, {2025, "R3-7"}, {2026, "R4-3"}],
    "Tiffany" => [{2023, "R1-6"}, {2024, "R2-5"}, {2025, "R3-5"}, {2026, "R4-8"}],
    "Alex" => [{2023, "R1-7"}, {2024, "R2-7"}, {2025, "R3-6"}, {2026, "R4-5"}],
    "Paige R" => [{2023, "R1-8"}, {2024, "R2-4"}, {2025, "R3-4"}, {2026, "R4-1"}],
    # 2024 R1s → 2025 R2s → 2026 R3s
    "Sarah" => [{2024, "R1-1"}, {2025, "R2-4"}, {2026, "R3-3"}],
    "Anna" => [{2024, "R1-2"}, {2025, "R2-8"}, {2026, "R3-2"}],
    "Olivia" => [{2024, "R1-3"}, {2025, "R2-5"}, {2026, "R3-6"}],
    "JD" => [{2024, "R1-4"}, {2025, "R2-6"}, {2026, "R3-5"}],
    "Ellie" => [{2024, "R1-5"}, {2025, "R2-1"}, {2026, "R3-1"}],
    "Malayna" => [{2024, "R1-6"}, {2025, "R2-7"}, {2026, "R3-4"}],
    "Kylie" => [{2024, "R1-7"}, {2025, "R2-2"}, {2026, "R3-7"}],
    "Emily F" => [{2024, "R1-8"}, {2025, "R2-3"}, {2026, "R3-8"}],
    # 2025 R1s → 2026 R2s
    "Manasa" => [{2025, "R1-1"}, {2026, "R2-8"}],
    "Mary" => [{2025, "R1-2"}, {2026, "R2-4"}],
    "Gina" => [{2025, "R1-3"}, {2026, "R2-5"}],
    "Zhenya" => [{2025, "R1-4"}, {2026, "R2-7"}],
    "Paige K" => [{2025, "R1-5"}, {2026, "R2-3"}],
    "Liz" => [{2025, "R1-6"}, {2026, "R2-6"}],
    "Erin" => [{2025, "R1-7"}, {2026, "R2-2"}],
    "Lexi" => [{2025, "R1-8"}, {2026, "R2-1"}],
    # 2026 R1s — newest cohort
    "Hannah" => [{2026, "R1-1"}],
    "Morolayo" => [{2026, "R1-2"}],
    "Hildegard" => [{2026, "R1-3"}],
    "Ellen" => [{2026, "R1-4"}],
    "Alexa" => [{2026, "R1-5"}],
    "Anna B" => [{2026, "R1-6"}],
    "Carolyn R" => [{2026, "R1-7"}],
    "Jake" => [{2026, "R1-8"}]
  }

  @canonical_names %{
    # ── 2023-2024 ─────────────────────────────────────────────────────────────
    # R4s — graduating, only this year
    {2023, "R4-1"} => "Alexis",
    {2023, "R4-2"} => "Emily",
    {2023, "R4-3"} => "Michelle",
    {2023, "R4-4"} => "Devin",
    {2023, "R4-5"} => "Joanna",
    {2023, "R4-6"} => "Yanling",
    {2023, "R4-7"} => "Victoria",
    # R3s
    {2023, "R3-1"} => "Kathryn",
    {2023, "R3-2"} => "Lila",
    {2023, "R3-3"} => "Tricia",
    {2023, "R3-4"} => "Leanne",
    {2023, "R3-5"} => "Savannah",
    {2023, "R3-6"} => "Pivi",
    {2023, "R3-7"} => "Aladeyemi",
    {2023, "R3-8"} => "Danielle",
    # R2s
    {2023, "R2-1"} => "Chima",
    {2023, "R2-2"} => "Laura",
    {2023, "R2-3"} => "Emily K",
    {2023, "R2-4"} => "Ally Z",
    {2023, "R2-5"} => "Annie",
    {2023, "R2-6"} => "Young",
    {2023, "R2-7"} => "Allie G",
    {2023, "R2-8"} => "Carolyn",
    # R1s
    {2023, "R1-1"} => "Carson",
    {2023, "R1-2"} => "Dana",
    {2023, "R1-3"} => "Grace",
    {2023, "R1-4"} => "Clare",
    {2023, "R1-5"} => "Emily Y",
    {2023, "R1-6"} => "Tiffany",
    {2023, "R1-7"} => "Alex",
    {2023, "R1-8"} => "Paige R",

    # ── 2024-2025 ─────────────────────────────────────────────────────────────
    # R4s
    {2024, "R4-1"} => "Lila",
    {2024, "R4-2"} => "Savannah",
    {2024, "R4-3"} => "Tricia",
    {2024, "R4-4"} => "Kathryn",
    {2024, "R4-5"} => "Aladeyemi",
    {2024, "R4-6"} => "Danielle",
    {2024, "R4-7"} => "Leanne",
    {2024, "R4-8"} => "Pivi",
    # R3s
    {2024, "R3-1"} => "Ally Z",
    {2024, "R3-2"} => "Allie G",
    {2024, "R3-3"} => "Annie",
    {2024, "R3-4"} => "Young",
    {2024, "R3-5"} => "Carolyn",
    {2024, "R3-6"} => "Emily K",
    {2024, "R3-7"} => "Laura",
    {2024, "R3-8"} => "Chima",
    # R2s
    {2024, "R2-1"} => "Emily Y",
    {2024, "R2-2"} => "Clare",
    {2024, "R2-3"} => "Dana",
    {2024, "R2-4"} => "Paige R",
    {2024, "R2-5"} => "Tiffany",
    {2024, "R2-6"} => "Carson",
    {2024, "R2-7"} => "Alex",
    {2024, "R2-8"} => "Grace",
    # R1s
    {2024, "R1-1"} => "Sarah",
    {2024, "R1-2"} => "Anna",
    {2024, "R1-3"} => "Olivia",
    {2024, "R1-4"} => "JD",
    {2024, "R1-5"} => "Ellie",
    {2024, "R1-6"} => "Malayna",
    {2024, "R1-7"} => "Kylie",
    {2024, "R1-8"} => "Emily F",

    # ── 2025-2026 ─────────────────────────────────────────────────────────────
    # R4s
    {2025, "R4-1"} => "Laura",
    {2025, "R4-2"} => "Young",
    {2025, "R4-3"} => "Carolyn",
    {2025, "R4-4"} => "Allie G",
    {2025, "R4-5"} => "Annie",
    {2025, "R4-6"} => "Chima",
    {2025, "R4-7"} => "Ally Z",
    {2025, "R4-8"} => "Emily K",
    # R3s
    {2025, "R3-1"} => "Clare",
    {2025, "R3-2"} => "Dana",
    {2025, "R3-3"} => "Carson",
    {2025, "R3-4"} => "Paige R",
    {2025, "R3-5"} => "Tiffany",
    {2025, "R3-6"} => "Alex",
    {2025, "R3-7"} => "Emily Y",
    {2025, "R3-8"} => "Grace",
    # R2s
    {2025, "R2-1"} => "Ellie",
    {2025, "R2-2"} => "Kylie",
    {2025, "R2-3"} => "Emily F",
    {2025, "R2-4"} => "Sarah",
    {2025, "R2-5"} => "Olivia",
    {2025, "R2-6"} => "JD",
    {2025, "R2-7"} => "Malayna",
    {2025, "R2-8"} => "Anna",
    # R1s
    {2025, "R1-1"} => "Manasa",
    {2025, "R1-2"} => "Mary",
    {2025, "R1-3"} => "Gina",
    {2025, "R1-4"} => "Zhenya",
    {2025, "R1-5"} => "Paige K",
    {2025, "R1-6"} => "Liz",
    {2025, "R1-7"} => "Erin",
    {2025, "R1-8"} => "Lexi",

    # ── 2026-2027 ─────────────────────────────────────────────────────────────

    # R4
    {2026, "R4-1"} => "Paige R",
    {2026, "R4-2"} => "Grace",
    {2026, "R4-3"} => "Emily Y",
    {2026, "R4-4"} => "Dana",
    {2026, "R4-5"} => "Alex",
    {2026, "R4-6"} => "Clare",
    {2026, "R4-7"} => "Carson",
    {2026, "R4-8"} => "Tiffany",

    # R3
    {2026, "R3-1"} => "Ellie",
    {2026, "R3-2"} => "Anna",
    {2026, "R3-3"} => "Sarah",
    {2026, "R3-4"} => "Malayna",
    {2026, "R3-5"} => "JD",
    {2026, "R3-6"} => "Olivia",
    {2026, "R3-7"} => "Kylie",
    {2026, "R3-8"} => "Emily F",

    # R2
    {2026, "R2-1"} => "Lexi",
    {2026, "R2-2"} => "Erin",
    {2026, "R2-3"} => "Paige K",
    {2026, "R2-4"} => "Mary",
    {2026, "R2-5"} => "Gina",
    {2026, "R2-6"} => "Liz",
    {2026, "R2-7"} => "Zhenya",
    {2026, "R2-8"} => "Manasa",

    # R1
    {2026, "R1-1"} => "Hannah",
    {2026, "R1-2"} => "Morolayo",
    {2026, "R1-3"} => "Hildegard",
    {2026, "R1-4"} => "Ellen",
    {2026, "R1-5"} => "Alexa",
    {2026, "R1-6"} => "Anna B",
    {2026, "R1-7"} => "Carolyn R",
    {2026, "R1-8"} => "Jake"
  }
  @doc """
  Returns the canonical name for a resident given their academic year start and
  position code. Falls back to the trimmed raw name if no mapping is found.

  Demo deployments keep the raw name from the CSV. The demo fixture covers the
  current academic year so it renders on the calendar, which is inside the range
  this map covers — without the bypass, its invented names would be rewritten to
  the real residents' names.

      iex> ResidencySchedule.Importer.NameNormalizer.normalize(2023, "R1-1", "Quinn Halden")
      "Carson"

      iex> ResidencySchedule.Importer.NameNormalizer.normalize(2025, "R4-4", "Allie ")
      "Allie G"

      iex> ResidencySchedule.Importer.NameNormalizer.normalize(2099, "R1-1", "Unknown Name")
      "Unknown Name"
  """
  def normalize(academic_year, position_code, raw_name) do
    if ResidencySchedule.demo_mode?() do
      String.trim(raw_name)
    else
      Map.get(@canonical_names, {academic_year, position_code}, String.trim(raw_name))
    end
  end

  @doc """
  Returns all schedule numbers for a canonical name.

      iex> ResidencySchedule.Importer.NameNormalizer.get_canonical_schedule_numbers("Emily K")
      [{2023, "R2-3"}, {2024, "R3-6"}, {2025, "R4-8"}]
  """
  def get_canonical_schedule_numbers(name) do
    Map.get(@canonincal_names_to_schedule_numbers, name, [])
  end

  @doc """
  Returns all distinct canonical names known to the normalizer.

      iex> ResidencySchedule.Importer.NameNormalizer.all_canonical_names() |> Enum.member?("Emily K")
      true
  """
  def all_canonical_names do
    @canonical_names
    |> Map.values()
    |> Enum.uniq()
  end
end
