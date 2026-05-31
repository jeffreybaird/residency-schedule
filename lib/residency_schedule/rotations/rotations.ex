defmodule ResidencySchedule.Rotations do
  import Ecto.Query
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Residents.ScheduleResident
  alias ResidencySchedule.ShiftOverrides

  @rotation_labels %{
    "ambulatory" => "Ambulatory",
    "away_rotation" => "Away Rotation",
    "elective" => "Elective",
    "float" => "Float",
    "strong_gynecology" => "Gynecology – Strong Memorial",
    "highland_gynecology" => "Gynecology – Highland",
    "highland_obstetrics" => "Obstetrics – Highland",
    "highland_night_float" => "Night Float – Highland",
    "highland_weekend_days" => "Weekend Days – Highland",
    "highland_weekend_nights" => "Weekend Nights – Highland",
    "night_float" => "Night Float – Strong",
    "strong_obstetrics" => "Obstetrics – Strong",
    "oncology" => "Oncology",
    "post_call" => "Post Call",
    "rei" => "Reproductive Endocrinology & Infertility",
    "strong_weekend_days" => "Weekend Days – Strong",
    "strong_weekend_nights" => "Weekend Nights – Strong",
    "swing" => "Swing Shift",
    "ultrasound" => "Ultrasound",
    "urogynecology" => "Uro-Gynecology",
    "unknown" => "Unknown",
    "vacation" => "Vacation"
  }

  @rotation_colors %{
    "strong_obstetrics" => "bg-blue-500 text-white",
    "strong_gynecology" => "bg-blue-400 text-white",
    "strong_weekend_days" => "bg-blue-300 text-gray-800",
    "strong_weekend_nights" => "bg-blue-800 text-white",
    "highland_obstetrics" => "bg-cyan-500 text-white",
    "highland_gynecology" => "bg-fuchsia-500 text-white",
    "oncology" => "bg-rose-700 text-white",
    "highland_weekend_days" => "bg-cyan-300 text-gray-800",
    "highland_weekend_nights" => "bg-cyan-800 text-white",
    "night_float" => "bg-indigo-700 text-white",
    "highland_night_float" => "bg-indigo-400 text-white",
    "post_call" => "bg-indigo-100 text-indigo-900",
    "ambulatory" => "bg-teal-500 text-white",
    "rei" => "bg-yellow-500 text-gray-900",
    "urogynecology" => "bg-orange-400 text-white",
    "elective" => "bg-violet-400 text-white",
    "away_rotation" => "bg-violet-200 text-violet-900",
    "swing" => "bg-lime-500 text-white",
    "ultrasound" => "bg-sky-400 text-white",
    "unknown" => "bg-gray-400 text-white",
    "vacation" => "bg-emerald-400 text-white",
    "float" => "bg-gray-300 text-gray-700"
  }

  @doc """
  Returns one `{slot_index, start_date, end_date}` per slot for a schedule,
  ordered by slot_index. Used to compute days-off gaps for a resident.

  When rotations in the same slot have varying date ranges — e.g. Highland
  night shifts shift or shrink the canonical slot boundaries — the most
  common `(start_date, end_date)` pair is returned as the canonical range,
  so each slot_index yields exactly one slot entry.
  """
  def list_schedule_slots(schedule_id) do
    from(r in Rotation,
      join: sr in assoc(r, :schedule_resident),
      where: sr.schedule_id == ^schedule_id,
      select: {r.slot_index, r.start_date, r.end_date}
    )
    |> Repo.all()
    |> Enum.group_by(fn {slot_index, _, _} -> slot_index end)
    |> Enum.map(fn {slot_index, entries} ->
      {start_date, end_date} = canonical_slot_range(entries)
      {slot_index, start_date, end_date}
    end)
    |> Enum.sort_by(fn {slot_index, _, _} -> slot_index end)
  end

  defp canonical_slot_range(entries) do
    entries
    |> Enum.map(fn {_slot_index, start_date, end_date} -> {start_date, end_date} end)
    |> Enum.frequencies()
    |> Enum.max_by(fn {_range, count} -> count end)
    |> elem(0)
  end

  @doc """
  Returns all rotations for a schedule resident, ordered by start_date.
  """
  def list_rotations_for_resident(schedule_resident_id) do
    Rotation
    |> where(schedule_resident_id: ^schedule_resident_id)
    |> order_by(asc: :start_date)
    |> Repo.all()
  end

  @doc """
  Returns all rotations in a date range (inclusive), across all residents.
  """
  def list_rotations_in_range(start_date, end_date) do
    Rotation
    |> where([r], r.start_date <= ^end_date and r.end_date >= ^start_date)
    |> order_by(asc: :start_date)
    |> Repo.all()
  end

  @doc """
  Returns all rotations active on a given date for a schedule, with schedule_resident preloaded.
  The schedule_resident virtual name field is populated from the associated Resident.
  """
  def list_rotations_for_date(date, schedule_id) do
    sr_query = ScheduleResident.with_name_query()

    from(rot in Rotation,
      join: sr in assoc(rot, :schedule_resident),
      where: sr.schedule_id == ^schedule_id,
      where: rot.start_date <= ^date and rot.end_date >= ^date,
      preload: [schedule_resident: ^sr_query],
      order_by: [rot.rotation_type, sr.residency_year, sr.schedule_number]
    )
    |> Repo.all()
  end

  @doc """
  Lists rotations for one schedule that match a rotation type and overlap the given date range
  (inclusive), with `schedule_resident` preloaded (virtual `name` from `Resident`).

  Exempt from doctest — hits the database. See `RotationsTest` for coverage.
  """
  def list_rotations_for_schedule_type_in_range(
        schedule_id,
        rotation_type,
        range_start,
        range_end
      ) do
    sr_query = ScheduleResident.with_name_query()

    from(rot in Rotation,
      join: sr in assoc(rot, :schedule_resident),
      where: sr.schedule_id == ^schedule_id,
      where: rot.rotation_type == ^rotation_type,
      where: rot.start_date <= ^range_end and rot.end_date >= ^range_start,
      preload: [schedule_resident: ^sr_query],
      order_by: [sr.residency_year, sr.schedule_number, rot.start_date]
    )
    |> Repo.all()
  end

  @doc """
  Builds effective assignment rows for one calendar day, applying shift coverage rules
  (same behavior as the calendar day modal).

  `rotations` must have `schedule_resident` preloaded. Each override must have
  `covering_schedule_resident` preloaded.

      iex> alias ResidencySchedule.Residents.ScheduleResident
      iex> alias ResidencySchedule.Rotations.Rotation
      iex> alias ResidencySchedule.ShiftOverrides.ShiftOverride
      iex> ann = %ScheduleResident{id: 1, residency_year: 4, schedule_number: 1, position_code: "R4-1", name: "Ann"}
      iex> bea = %ScheduleResident{id: 2, residency_year: 2, schedule_number: 1, position_code: "R2-1", name: "Bea"}
      iex> rot = %Rotation{id: 10, rotation_type: "oncology", schedule_resident_id: 1, schedule_resident: ann}
      iex> ov = %ShiftOverride{
      ...>   rotation_id: 10,
      ...>   covering_schedule_resident_id: 2,
      ...>   covering_schedule_resident: bea,
      ...>   override_start_date: ~D[2023-07-01],
      ...>   override_end_date: ~D[2023-07-31]
      ...> }
      iex> rows = ResidencySchedule.Rotations.effective_day_assignments([rot], [ov])
      iex> length(rows)
      2
      iex> Enum.at(rows, 1).is_coverage
      true
  """
  def effective_day_assignments(rotations, overrides)
      when is_list(rotations) and is_list(overrides) do
    override_by_rotation = Map.new(overrides, fn o -> {o.rotation_id, o} end)
    covering_today = MapSet.new(overrides, & &1.covering_schedule_resident_id)

    Enum.flat_map(rotations, fn rot ->
      if MapSet.member?(covering_today, rot.schedule_resident_id) do
        []
      else
        case Map.get(override_by_rotation, rot.id) do
          nil ->
            [
              %{
                resident: rot.schedule_resident,
                rotation_type: rot.rotation_type,
                overridden: false,
                covered_by: nil,
                is_coverage: false
              }
            ]

          override ->
            [
              %{
                resident: rot.schedule_resident,
                rotation_type: rot.rotation_type,
                overridden: true,
                covered_by: override.covering_schedule_resident,
                is_coverage: false
              },
              %{
                resident: override.covering_schedule_resident,
                rotation_type: rot.rotation_type,
                overridden: false,
                covered_by: nil,
                is_coverage: true
              }
            ]
        end
      end
    end)
    |> Enum.sort_by(fn e ->
      {e.rotation_type, e.resident.residency_year, e.resident.schedule_number}
    end)
  end

  @doc """
  Effective modal rows for one rotation type on a schedule over an inclusive date range,
  reflecting shift overrides per day.

  Each row is a map with `:resident`, `:overridden`, `:covered_by`, `:is_coverage`, and
  `:active_dates` (`MapSet` of dates in the range when that row applies).

  Exempt from doctest — hits the database. See `RotationsTest`.
  """
  def list_effective_coworker_rows_for_type_in_range(
        schedule_id,
        rotation_type,
        range_start,
        range_end
      ) do
    overrides =
      ShiftOverrides.list_overrides_for_schedule_in_range(
        schedule_id,
        range_start,
        range_end
      )

    range_start
    |> Date.range(range_end)
    |> Enum.reduce(%{}, fn date, acc ->
      rotations = list_rotations_for_date(date, schedule_id)

      day_overrides =
        Enum.filter(overrides, fn o ->
          Date.compare(date, o.override_start_date) != :lt and
            Date.compare(date, o.override_end_date) != :gt
        end)

      rotations
      |> effective_day_assignments(day_overrides)
      |> Enum.filter(&(&1.rotation_type == rotation_type))
      |> Enum.reduce(acc, fn entry, acc2 -> accumulate_coworker_row(acc2, date, entry) end)
    end)
    |> Map.values()
    |> Enum.map(fn %{template: t, dates: dates} -> Map.put(t, :active_dates, dates) end)
    |> Enum.sort_by(&coworker_modal_row_sort_key/1)
  end

  @doc """
  Lists schedule residents who have no rotation for the given `slot_index` on each day in the
  inclusive date range (same notion of “off” as the resident schedule table: unassigned for
  that slot in that block). Each row matches the coworker modal shape with `:active_dates`.

  Exempt from doctest — hits the database. See `RotationsTest`.
  """
  def list_off_coworker_rows_for_slot_in_range(
        schedule_id,
        slot_index,
        range_start,
        range_end
      ) do
    srs = Residents.list_residents_for_schedule(schedule_id)

    busy_intervals =
      from(r in Rotation,
        join: sr in assoc(r, :schedule_resident),
        where: sr.schedule_id == ^schedule_id,
        where: r.slot_index == ^slot_index,
        where: r.start_date <= ^range_end and r.end_date >= ^range_start,
        select: {sr.id, r.start_date, r.end_date}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), fn {_, s, e} -> {s, e} end)

    range_start
    |> Date.range(range_end)
    |> Enum.reduce(%{}, fn date, acc ->
      Enum.reduce(srs, acc, fn sr, acc2 ->
        intervals = Map.get(busy_intervals, sr.id, [])

        busy? =
          Enum.any?(intervals, fn {s, e} ->
            Date.compare(date, s) != :lt and Date.compare(date, e) != :gt
          end)

        if busy? do
          acc2
        else
          Map.update(acc2, sr.id, MapSet.new([date]), &MapSet.put(&1, date))
        end
      end)
    end)
    |> Enum.map(fn {sr_id, dates} ->
      sr = Enum.find(srs, &(&1.id == sr_id))

      %{
        resident: sr,
        active_dates: dates,
        overridden: false,
        covered_by: nil,
        is_coverage: false
      }
    end)
    |> Enum.sort_by(&{&1.resident.residency_year, &1.resident.schedule_number})
  end

  @doc """
  Renders which days in `dates` fall inside `[block_start, block_end]` as comma-separated ranges.

      iex> dates = MapSet.new([~D[2023-07-03], ~D[2023-07-04], ~D[2023-07-06]])
      iex> ResidencySchedule.Rotations.format_date_set_within_block(dates, ~D[2023-07-03], ~D[2023-07-07])
      "Jul 3–4, Jul 6"

      iex> ResidencySchedule.Rotations.format_date_set_within_block(MapSet.new(), ~D[2023-07-01], ~D[2023-07-31])
      "—"
  """
  def format_date_set_within_block(%MapSet{} = dates, block_start, block_end) do
    dates
    |> MapSet.to_list()
    |> Enum.filter(fn d ->
      Date.compare(d, block_start) != :lt and Date.compare(d, block_end) != :gt
    end)
    |> Enum.sort(Date)
    |> chunk_consecutive_dates()
    |> Enum.map(&interval_label_for_dates/1)
    |> case do
      [] -> "—"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp accumulate_coworker_row(acc, date, entry) do
    key = coworker_row_key(entry)

    template = %{
      resident: entry.resident,
      overridden: entry.overridden,
      covered_by: entry.covered_by,
      is_coverage: entry.is_coverage
    }

    Map.update(acc, key, %{dates: MapSet.new([date]), template: template}, fn existing ->
      %{existing | dates: MapSet.put(existing.dates, date)}
    end)
  end

  defp coworker_row_key(entry) do
    cover_id = if entry.covered_by, do: entry.covered_by.id, else: nil
    {entry.resident.id, entry.overridden, entry.is_coverage, cover_id}
  end

  defp coworker_modal_row_sort_key(row) do
    {
      row.resident.residency_year,
      row.resident.schedule_number,
      row.is_coverage,
      row.overridden
    }
  end

  defp chunk_consecutive_dates([]), do: []

  defp chunk_consecutive_dates([first | rest]) do
    {chunk, remaining} = take_consecutive(rest, first, [first])
    [chunk | chunk_consecutive_dates(remaining)]
  end

  defp take_consecutive([], _last, acc), do: {Enum.reverse(acc), []}

  defp take_consecutive([y | ys], last, acc) do
    if Date.diff(y, last) == 1 do
      take_consecutive(ys, y, [y | acc])
    else
      {Enum.reverse(acc), [y | ys]}
    end
  end

  defp interval_label_for_dates([d]),
    do: Calendar.strftime(d, "%b %-d, %Y")

  defp interval_label_for_dates(chunk) do
    a = List.first(chunk)
    b = List.last(chunk)
    "#{Calendar.strftime(a, "%b %-d, %Y")}–#{Calendar.strftime(b, "%b %-d, %Y")}"
  end

  @doc """
  Returns all rotations for a given month and schedule, with schedule_resident preloaded.
  The schedule_resident virtual name field is populated from the associated Resident.
  """
  def list_rotations_for_month(year, month, schedule_id) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)
    sr_query = ScheduleResident.with_name_query()

    from(rot in Rotation,
      join: sr in assoc(rot, :schedule_resident),
      where: sr.schedule_id == ^schedule_id,
      where: rot.start_date <= ^last and rot.end_date >= ^first,
      preload: [schedule_resident: ^sr_query]
    )
    |> Repo.all()
  end

  @doc """
  Returns all rotations for a given month across all schedules, with schedule_resident preloaded.
  The schedule_resident virtual name field is populated from the associated Resident.
  """
  def list_rotations_for_month_all_schedules(year, month) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)
    sr_query = ScheduleResident.with_name_query()

    from(rot in Rotation,
      join: sr in assoc(rot, :schedule_resident),
      where: rot.start_date <= ^last and rot.end_date >= ^first,
      preload: [schedule_resident: ^sr_query]
    )
    |> Repo.all()
  end

  @doc """
  Returns all rotations overlapping an inclusive date range across all schedules,
  with `schedule_resident` preloaded (virtual `name` from `Resident`).

  Powers the calendar's week and day views, which span arbitrary date ranges
  rather than a single calendar month.

      iex> ResidencySchedule.Rotations.list_rotations_in_range_all_schedules(~D[2000-01-01], ~D[2000-01-07])
      []
  """
  def list_rotations_in_range_all_schedules(range_start, range_end) do
    sr_query = ScheduleResident.with_name_query()

    from(rot in Rotation,
      join: sr in assoc(rot, :schedule_resident),
      where: rot.start_date <= ^range_end and rot.end_date >= ^range_start,
      preload: [schedule_resident: ^sr_query]
    )
    |> Repo.all()
  end

  @doc """
  Keeps only rotations belonging to one of the given residents (people).

  Matches on the preloaded `schedule_resident`'s `resident_id`, so a resident is
  matched across every academic year they appear in (each year is a distinct
  `schedule_resident` for the same person). An empty list applies no filter.

      iex> alias ResidencySchedule.Rotations.Rotation
      iex> alias ResidencySchedule.Residents.ScheduleResident
      iex> rots = [
      ...>   %Rotation{id: 1, schedule_resident: %ScheduleResident{resident_id: 7}},
      ...>   %Rotation{id: 2, schedule_resident: %ScheduleResident{resident_id: 9}}
      ...> ]
      iex> ResidencySchedule.Rotations.filter_rotations_by_residents(rots, [7]) |> Enum.map(& &1.id)
      [1]
  """
  def filter_rotations_by_residents(rotations, []), do: rotations

  def filter_rotations_by_residents(rotations, resident_ids) do
    id_set = MapSet.new(resident_ids)
    Enum.filter(rotations, &MapSet.member?(id_set, &1.schedule_resident.resident_id))
  end

  @doc """
  Keeps only rotations whose `rotation_type` is one of the given `types`.
  An empty `types` list applies no filter and returns the rotations unchanged.

      iex> alias ResidencySchedule.Rotations.Rotation
      iex> rots = [%Rotation{id: 1, rotation_type: "oncology"}, %Rotation{id: 2, rotation_type: "vacation"}]
      iex> ResidencySchedule.Rotations.filter_rotations_by_types(rots, ["oncology"]) |> Enum.map(& &1.id)
      [1]
  """
  def filter_rotations_by_types(rotations, []), do: rotations

  def filter_rotations_by_types(rotations, types) do
    type_set = MapSet.new(types)
    Enum.filter(rotations, &MapSet.member?(type_set, &1.rotation_type))
  end

  @doc """
  Returns rotations filtered by rotation type.
  """
  def list_rotations_by_type(rotation_type) do
    Rotation
    |> where(rotation_type: ^rotation_type)
    |> order_by(asc: :start_date)
    |> Repo.all()
  end

  @doc """
  Returns co-service days (same rotation type, overlapping dates) for two schedule residents.
  """
  def list_co_service_days(schedule_resident_a_id, schedule_resident_b_id) do
    from(a in Rotation,
      join: b in Rotation,
      on:
        b.schedule_resident_id == ^schedule_resident_b_id and b.rotation_type == a.rotation_type,
      where: a.schedule_resident_id == ^schedule_resident_a_id,
      where: a.rotation_type not in ["float", "post_call", "vacation", "ambulatory", "elective"],
      where: a.start_date <= b.end_date and a.end_date >= b.start_date,
      select: %{
        overlap_start: fragment("GREATEST(?, ?)", a.start_date, b.start_date),
        overlap_end: fragment("LEAST(?, ?)", a.end_date, b.end_date),
        rotation_type: a.rotation_type
      }
    )
    |> Repo.all()
    |> Enum.flat_map(fn %{overlap_start: start, overlap_end: finish, rotation_type: type} ->
      Date.range(start, finish) |> Enum.map(&%{date: &1, rotation_type: type})
    end)
    |> Enum.sort_by(& &1.date, Date)
  end

  @doc """
  Computes effective rotation segments for a schedule resident, accounting for shift overrides.

  Returns a sorted list of maps, each with:
  - `:rotation_type` — the rotation type string
  - `:start_date` — effective start date of this segment
  - `:end_date` — effective end date of this segment
  - `:slot_index` — original slot index (-1 for coverage assignments)
  - `:is_coverage` — true when this segment is a coverage assignment for another resident
  - `:covered_by` — the covering ScheduleResident struct when someone is covering this segment, else nil
  - `:original_resident` — the ScheduleResident being covered when `is_coverage: true`, else nil

      iex> ResidencySchedule.Rotations.effective_segments_for_resident(0)
      []
  """
  def effective_segments_for_resident(schedule_resident_id) do
    alias ResidencySchedule.ShiftOverrides

    rotations = list_rotations_for_resident(schedule_resident_id)

    overrides_as_original =
      ShiftOverrides.list_overrides_for_resident_as_original(schedule_resident_id)

    overrides_as_cover = ShiftOverrides.list_overrides_for_resident_as_cover(schedule_resident_id)

    covered_blocks =
      Enum.map(overrides_as_original, fn o ->
        {o.override_start_date, o.override_end_date, {:covered_by, o.covering_schedule_resident}}
      end)

    covering_blocks =
      Enum.map(overrides_as_cover, fn o ->
        {o.override_start_date, o.override_end_date, :covering_elsewhere}
      end)

    all_blocks = covered_blocks ++ covering_blocks

    own_segments =
      Enum.flat_map(rotations, fn rot ->
        overlapping =
          all_blocks
          |> Enum.filter(fn {bs, be, _} ->
            Date.compare(bs, rot.end_date) != :gt and Date.compare(be, rot.start_date) != :lt
          end)
          |> Enum.sort_by(&elem(&1, 0), Date)

        split_by_blocks(rot, overlapping)
      end)

    coverage_segments =
      Enum.map(overrides_as_cover, fn o ->
        %{
          rotation_type: o.rotation.rotation_type,
          start_date: o.override_start_date,
          end_date: o.override_end_date,
          slot_index: -1,
          is_coverage: true,
          covered_by: nil,
          original_resident: o.rotation.schedule_resident
        }
      end)

    (own_segments ++ coverage_segments)
    |> Enum.sort_by(& &1.start_date, Date)
  end

  defp split_by_blocks(rotation, []) do
    [
      %{
        rotation_type: rotation.rotation_type,
        start_date: rotation.start_date,
        end_date: rotation.end_date,
        slot_index: rotation.slot_index,
        is_coverage: false,
        covered_by: nil,
        original_resident: nil
      }
    ]
  end

  defp split_by_blocks(rotation, blocks) do
    base = %{
      rotation_type: rotation.rotation_type,
      slot_index: rotation.slot_index,
      is_coverage: false,
      original_resident: nil,
      start_date: rotation.start_date,
      end_date: rotation.end_date,
      covered_by: nil
    }

    clamped =
      blocks
      |> Enum.map(fn {bs, be, meta} ->
        {Enum.max([bs, rotation.start_date], Date), Enum.min([be, rotation.end_date], Date), meta}
      end)
      |> Enum.filter(fn {bs, be, _} -> Date.compare(bs, be) != :gt end)
      |> Enum.sort_by(&elem(&1, 0), Date)

    {segments, current} =
      Enum.reduce(clamped, {[], rotation.start_date}, fn {bs, be, meta}, {segs, start} ->
        effective_bs = Enum.max([bs, start], Date)

        pre =
          if Date.compare(start, effective_bs) == :lt do
            [%{base | start_date: start, end_date: Date.add(effective_bs, -1), covered_by: nil}]
          else
            []
          end

        covered =
          case meta do
            {:covered_by, resident} ->
              [%{base | start_date: effective_bs, end_date: be, covered_by: resident}]

            :covering_elsewhere ->
              []
          end

        next_start = Date.add(be, 1)
        {segs ++ pre ++ covered, Enum.max([start, next_start], Date)}
      end)

    post =
      if Date.compare(current, rotation.end_date) != :gt do
        [%{base | start_date: current, end_date: rotation.end_date, covered_by: nil}]
      else
        []
      end

    Enum.filter(segments ++ post, fn seg ->
      Date.compare(seg.start_date, seg.end_date) != :gt
    end)
  end

  @doc """
  Computes effective co-service days for two schedule residents, accounting for shift overrides.
  Returns a list of `%{date: Date, rotation_type: String}` maps for days both residents
  are on the same service (excluding float, post_call, vacation, ambulatory, elective).
  """
  def list_effective_co_service_days(schedule_resident_a_id, schedule_resident_b_id) do
    excluded = ~w[float post_call vacation ambulatory elective]

    segs_a =
      effective_segments_for_resident(schedule_resident_a_id)
      |> Enum.reject(fn s -> s.covered_by != nil or s.rotation_type in excluded end)

    segs_b =
      effective_segments_for_resident(schedule_resident_b_id)
      |> Enum.reject(fn s -> s.covered_by != nil or s.rotation_type in excluded end)

    for a <- segs_a,
        b <- segs_b,
        a.rotation_type == b.rotation_type,
        Date.compare(a.start_date, b.end_date) != :gt,
        Date.compare(a.end_date, b.start_date) != :lt do
      overlap_start = Enum.max([a.start_date, b.start_date], Date)
      overlap_end = Enum.min([a.end_date, b.end_date], Date)

      Date.range(overlap_start, overlap_end)
      |> Enum.map(&%{date: &1, rotation_type: a.rotation_type})
    end
    |> List.flatten()
    |> Enum.sort_by(& &1.date, Date)
  end

  @doc """
  Inserts a batch of rotation records for a schedule resident.
  Returns `{:ok, count}` or `{:error, reason}`.
  """
  def insert_rotations(schedule_resident_id, rotations) do
    now = DateTime.utc_now(:second)

    entries =
      Enum.map(rotations, fn r ->
        %{
          schedule_resident_id: schedule_resident_id,
          rotation_type: Atom.to_string(r.rotation_type),
          start_date: r.start_date,
          end_date: r.end_date,
          slot_index: r.slot_index,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, _} = Repo.insert_all(Rotation, entries)
    {:ok, count}
  end

  @doc """
  Returns the human-readable label for a rotation type string.

      iex> ResidencySchedule.Rotations.rotation_type_label("oncology")
      "Oncology"

      iex> ResidencySchedule.Rotations.rotation_type_label("night_float")
      "Night Float – Strong"
  """
  def rotation_type_label(rotation_type) do
    Map.get(@rotation_labels, rotation_type, rotation_type)
  end

  @doc """
  Returns the Tailwind CSS classes for a rotation type string.

      iex> ResidencySchedule.Rotations.rotation_type_color("oncology")
      "bg-rose-700 text-white"

      iex> ResidencySchedule.Rotations.rotation_type_color("unknown_type")
      "bg-gray-200 text-gray-600"
  """
  def rotation_type_color(rotation_type) do
    Map.get(@rotation_colors, rotation_type, "bg-gray-200 text-gray-600")
  end

  @doc """
  Returns the list of all known rotation type strings.

      iex> "oncology" in ResidencySchedule.Rotations.all_rotation_types()
      true
  """
  def all_rotation_types do
    Map.keys(@rotation_labels)
  end
end
