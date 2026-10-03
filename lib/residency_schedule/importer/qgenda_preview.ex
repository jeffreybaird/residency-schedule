defmodule ResidencySchedule.Importer.QgendaPreview do
  @moduledoc "Read-only reconciliation of QGenda detail against a selected academic-year roster."
  alias ResidencySchedule.Importer.{Csv, QgendaParser}
  alias ResidencySchedule.{Residents, Schedules}

  @known_tasks [
    "Admin Resident AM",
    "Admin Resident PM",
    "Ambulatory R1",
    "Ambulatory R2",
    "Ambulatory R3",
    "Ambulatory R4",
    "Breastfeeding Clinic Resident AM",
    "COB Colpo Clinic PM",
    "COB Continuity Clinic AM",
    "COB Continuity Clinic PM",
    "Conference",
    "Elective R3",
    "Elective R4",
    "Exam",
    "Family Planning AM 8:30a-12p",
    "Family Planning PM 12p-5p",
    "Family Planning Resident AM",
    "Family Planning Resident PM",
    "GOG Colpo Clinic PM",
    "GOG Continuity Clinic AM",
    "GOG Continuity Clinic PM",
    "HH GYN ONC R1",
    "HH GYN ONC R2",
    "HH GYN ONC R3",
    "HH GYN ONC R4",
    "HH GYN R1",
    "HH GYN R2",
    "HH GYN R3",
    "HH GYN R4",
    "HH Nights 2nd Call",
    "HH Nights 3rd Call",
    "HH Nights Extra",
    "HH OB Day FM Fellow",
    "HH OB Day R2",
    "HH Weekend 2nd Call",
    "HH Weekend 3rd Call",
    "HH Weekend Extra",
    "Interview",
    "Interview - Residency",
    "Interview Full Day",
    "Interview PM",
    "Lattimore MFM Clinic AM",
    "Lattimore MFM Clinic PM",
    "Menopause Clinic AM",
    "NMH GYN 1st call Day 7:30a-6p",
    "NMH GYN 1st call Night 6p-7:30a",
    "NMH OB 2nd Call Day 7:30a-6p",
    "NMH OB 2nd Call Night 6p-7:30a",
    "OB Admin Chief ON CALL",
    "Pediatric GYN Clinic AM",
    "Pelvic Pain Clinic PM",
    "Post-Call",
    "Post-Loss Follow up 8a-5p",
    "REI Resident",
    "Research",
    "SMH GYN R2 Day",
    "SMH GYN R3 Day",
    "SMH Gynecology Chief On Call Day",
    "SMH Gynecology Chief On Call Night",
    "SMH Gynecology Intern On Call Day",
    "SMH Gynecology Intern On Call Night",
    "SMH HR OB wkday NIGHT- Blue Team 5p-10:30p",
    "SMH HR OB wkday NIGHT- Blue Team 5p-7:30a",
    "SMH HR OB wkday NIGHT- Blue Team 5p-8a",
    "SMH HR Weekend DAY- Blue Team 8a-5p",
    "SMH High Risk Obstetrics Attending 5p-7:30a",
    "SMH High Risk Obstetrics Attending 5p-8a",
    "SMH High Risk Obstetrics Attending 7:30a-5p",
    "SMH OBGYN Notes",
    "SMH Obstetrics Resident 1st Contact Day",
    "SMH Obstetrics Resident 1st Contact Night",
    "SMH Obstetrics Resident 2nd Contact Day",
    "SMH Obstetrics Resident 2nd Contact Night",
    "SMH Obstetrics Resident 3rd Contact Day",
    "SMH Obstetrics Resident 3rd Contact Night",
    "SMH Obstetrics Resident 4th Contact Day",
    "SMH Obstetrics Resident 4th Contact Night",
    "SMH Triage APP X COMP 7a-5p",
    "Sick Backup",
    "Surgical Simulation AM",
    "Swing Resident",
    "Time Away",
    "Ultrasound",
    "Urogyn Clinic Resident PM",
    "Urogyn Resident",
    "Vacation",
    "Vulvar Clinic PM",
    "conference - off site"
  ]

  @doc """
  Prepares a preview using an existing academic year. Never writes records.
  Database function; covered by integration tests instead of doctests.
  """
  def prepare(binary, options) do
    year = Keyword.get(options, :academic_year)

    with true <- is_integer(year),
         schedule when not is_nil(schedule) <- Schedules.get_by_year(year),
         {:ok, parsed} <- QgendaParser.parse(binary) do
      {configured_aliases, warnings} = load_crosswalk(year)
      aliases = Map.merge(configured_aliases, Keyword.get(options, :aliases, %{}))
      roster = Residents.list_residents_for_schedule(schedule.id)
      {:ok, build(parsed, roster, aliases: aliases) |> Map.put(:warnings, warnings)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Select an existing academic-year schedule for the preview."}
    end
  end

  @doc """
  Reconciles parsed assignments with an explicit roster without database access.

      iex> {:ok, parsed} = ResidencySchedule.Importer.QgendaParser.parse(File.read!("test/fixtures/qgenda/shared.xlsx"))
      iex> roster = [%{id: 1, resident_id: 2, name: "Iris Reed", position_code: "R2-1"}]
      iex> preview = ResidencySchedule.Importer.QgendaPreview.build(parsed, roster, [])
      iex> hd(preview.assignments).resident_id
      2
  """
  def build(parsed, roster, options) do
    aliases = Keyword.get(options, :aliases, %{})

    matches =
      parsed.assignments
      |> Enum.map(& &1.raw_staff)
      |> Enum.uniq()
      |> Enum.map(&match_person(&1, roster, aliases))

    by_staff = Map.new(matches, &{&1.raw_staff, &1})

    assignments =
      Enum.map(parsed.assignments, fn assignment ->
        match = Map.fetch!(by_staff, assignment.raw_staff)

        Map.merge(
          assignment,
          Map.take(match, [
            :resident_id,
            :schedule_resident_id,
            :display_name,
            :previous_name,
            :status
          ])
        )
      end)

    matched = Enum.reject(assignments, &is_nil(&1.resident_id))
    covered = matched |> Enum.map(& &1.date) |> MapSet.new()
    found = matched |> Enum.map(& &1.schedule_resident_id) |> MapSet.new()

    %{
      assignments: assignments,
      matches: matches,
      missing_residents: Enum.reject(roster, &MapSet.member?(found, &1.id)),
      unknown_tasks:
        assignments
        |> Enum.map(& &1.raw_task)
        |> Enum.uniq()
        |> Enum.reject(&(&1 in @known_tasks))
        |> Enum.sort(),
      header_range: date_range(parsed.header_dates),
      resident_range: date_range(MapSet.to_list(covered)),
      uncovered_dates: Enum.reject(parsed.header_dates, &MapSet.member?(covered, &1)),
      notes: parsed.notes,
      unlinked_notes: parsed.unlinked_notes,
      fingerprint:
        :crypto.hash(:sha256, :erlang.term_to_binary(parsed)) |> Base.encode16(case: :lower),
      warnings: []
    }
  end

  defp match_person(raw, roster, aliases) do
    display = display_name(raw)

    exact =
      Enum.filter(
        roster,
        &(normalize(&1.name) == normalize(display) and String.contains?(display, " "))
      )

    candidates = if exact == [], do: alias_candidates(raw, roster, aliases), else: exact

    base = %{
      raw_staff: raw,
      display_name: display,
      previous_name: nil,
      resident_id: nil,
      schedule_resident_id: nil
    }

    case candidates do
      [resident] ->
        Map.merge(base, %{
          status: :matched,
          previous_name: resident.name,
          resident_id: resident.resident_id,
          schedule_resident_id: resident.id
        })

      [] ->
        Map.put(base, :status, :unmatched)

      _ ->
        Map.put(base, :status, :ambiguous)
    end
  end

  defp alias_candidates(raw, roster, aliases) do
    case Map.get(aliases, raw) do
      %{position_code: code, expected_name: expected} ->
        Enum.filter(roster, &(&1.position_code == code and &1.name == expected))

      _ ->
        []
    end
  end

  defp display_name(raw) do
    case String.split(raw, ",", parts: 2) do
      [last, first] -> String.trim(first) <> " " <> String.trim(last)
      [name] -> String.trim(name)
    end
  end

  defp normalize(name),
    do: name |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, " ")

  defp date_range([]), do: nil
  defp date_range(dates), do: {Enum.min(dates, Date), Enum.max(dates, Date)}

  defp load_crosswalk(year) do
    path =
      Application.get_env(
        :residency_schedule,
        :qgenda_crosswalk_path,
        "data/qgenda-resident-crosswalk.csv"
      )

    case File.read(path) do
      {:ok, binary} ->
        {parse_crosswalk(binary, year), []}

      {:error, _} ->
        {%{},
         [
           "No reviewed QGenda name crosswalk is configured. Only unambiguous full names are matched."
         ]}
    end
  rescue
    _ ->
      {%{},
       [
         "The reviewed QGenda name crosswalk could not be read. Only unambiguous full names are matched."
       ]}
  end

  defp parse_crosswalk(binary, year) do
    [header | rows] = Csv.parse(binary)
    required = ~w(academic_year position_code qgenda_staff existing_name)

    if not Enum.all?(required, &(&1 in header)) or
         Enum.any?(rows, &(length(&1) != length(header))),
       do: raise(ArgumentError)

    rows
    |> Enum.map(&Map.new(Enum.zip(header, &1)))
    |> Enum.filter(&(&1["academic_year"] == Integer.to_string(year)))
    |> Enum.group_by(& &1["qgenda_staff"])
    |> Enum.flat_map(fn
      {raw, [row]} when is_binary(raw) and raw != "" ->
        [{raw, %{position_code: row["position_code"], expected_name: row["existing_name"]}}]

      _ ->
        []
    end)
    |> Map.new()
  end
end
