defmodule ResidencySchedule.Rotations do
  import Ecto.Query
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Rotations.Rotation

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
      join: res in assoc(r, :resident),
      where: res.schedule_id == ^schedule_id,
      select: {r.slot_index, r.start_date, r.end_date},
      distinct: true,
      order_by: r.slot_index
    )
    |> Repo.all()
  end

  @doc """
  Returns all rotations for a resident, ordered by start_date.
  """
  def list_rotations_for_resident(resident_id) do
    Rotation
    |> where(resident_id: ^resident_id)
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
  Returns all rotations active on a given date for a schedule, with resident preloaded.
  """
  def list_rotations_for_date(date, schedule_id) do
    from(rot in Rotation,
      join: res in assoc(rot, :resident),
      where: res.schedule_id == ^schedule_id,
      where: rot.start_date <= ^date and rot.end_date >= ^date,
      preload: [resident: res],
      order_by: [rot.rotation_type, res.residency_year, res.schedule_number]
    )
    |> Repo.all()
  end

  @doc """
  Returns all rotations for a given month and schedule, with resident preloaded.
  """
  def list_rotations_for_month(year, month, schedule_id) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)

    from(rot in Rotation,
      join: res in assoc(rot, :resident),
      where: res.schedule_id == ^schedule_id,
      where: rot.start_date <= ^last and rot.end_date >= ^first,
      preload: [resident: res]
    )
    |> Repo.all()
  end

  @doc """
  Returns all rotations for a given month across all schedules, with resident preloaded.
  """
  def list_rotations_for_month_all_schedules(year, month) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)

    from(rot in Rotation,
      join: res in assoc(rot, :resident),
      where: rot.start_date <= ^last and rot.end_date >= ^first,
      preload: [resident: res]
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
  Returns co-service days (same rotation type, overlapping dates) for two residents.
  """
  def list_co_service_days(resident_a_id, resident_b_id) do
    from(a in Rotation,
      join: b in Rotation,
      on: b.resident_id == ^resident_b_id and b.rotation_type == a.rotation_type,
      where: a.resident_id == ^resident_a_id,
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
  Inserts a batch of rotation records for a resident.
  Returns `{:ok, count}` or `{:error, reason}`.
  """
  def insert_rotations(resident_id, rotations) do
    now = DateTime.utc_now(:second)

    entries =
      Enum.map(rotations, fn r ->
        %{
          resident_id: resident_id,
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
