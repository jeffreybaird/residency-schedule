defmodule ResidencySchedule.Rotations do
  import Ecto.Query
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.Residents.ScheduleResident

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
  Returns all distinct slots (slot_index, start_date, end_date) for a schedule,
  ordered by slot_index. Used to compute days-off gaps for a resident.
  """
  def list_schedule_slots(schedule_id) do
    from(r in Rotation,
      join: sr in assoc(r, :schedule_resident),
      where: sr.schedule_id == ^schedule_id,
      select: {r.slot_index, r.start_date, r.end_date},
      distinct: true,
      order_by: r.slot_index
    )
    |> Repo.all()
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
