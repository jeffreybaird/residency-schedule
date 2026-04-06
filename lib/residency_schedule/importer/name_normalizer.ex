my defmodule ResidencySchedule.Importer.NameNormalizer do
  @moduledoc """
  Maps raw resident names to canonical first-name forms.

  Names are keyed by {academic_year_start, position_code} because the same
  position code refers to a different person across years, and the same person
  may appear with different spellings or full names in different years.

  Residents with ambiguous first names keep a disambiguating suffix:
  Ally Z, Allie G, Emily K, Emily Y, Emily F, JD, Paige R, Paige K.
  """

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
    {2025, "R1-4"} => "Evdokiya",
    {2025, "R1-5"} => "Paige K",
    {2025, "R1-6"} => "Elizabeth",
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

      iex> ResidencySchedule.Importer.NameNormalizer.normalize(2023, "R1-1", "Quinn Halden")
      "Carson"

      iex> ResidencySchedule.Importer.NameNormalizer.normalize(2025, "R4-4", "Allie ")
      "Allie G"

      iex> ResidencySchedule.Importer.NameNormalizer.normalize(2099, "R1-1", "Unknown Name")
      "Unknown Name"
  """
  def normalize(academic_year, position_code, raw_name) do
    Map.get(@canonical_names, {academic_year, position_code}, String.trim(raw_name))
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
