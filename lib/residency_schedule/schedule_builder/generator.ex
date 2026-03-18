defmodule ResidencySchedule.ScheduleBuilder.Generator do
  @moduledoc """
  Generates a valid schedule assignment matrix from a resident roster and slot list.

  The assignment map is keyed by `{resident_index, slot_index}` and maps to a
  rotation type atom. Residents are indexed 0-based in the order returned by
  `ResidentRoster.build_residents/0`.

  Generation is three-phase:
  1. Backbone: round-robin assignment of mandatory service rotations (OB, ONC, GYN,
     AMB, NF, HHOB), one per year level per slot, cycling evenly through residents.
  2. Electives: fill remaining weekday slots with year-specific and common rotations.
  3. Weekend derivation: auto-assign weekend coverage based on weekday rotation.
  """

  alias ResidencySchedule.ScheduleBuilder.ResidentRoster

  # Backbone rotations: {rotation_type, allowed_years}
  # One resident per year level per slot for each backbone rotation.
  @backbone [
    {:strong_obstetrics, [1, 2, 3, 4]},
    {:oncology, [1, 2, 3, 4]},
    {:strong_gynecology, [1, 2, 3, 4]},
    {:ambulatory, [1, 2, 3, 4]},
    {:night_float, [1, 2, 3, 4]},
    {:highland_obstetrics, [2]}
  ]

  # Weekend derivation: weekday rotation → weekend coverage type
  @weekend_map %{
    strong_obstetrics: :strong_weekend_days,
    strong_gynecology: :strong_weekend_days,
    highland_obstetrics: :strong_weekend_days,
    ambulatory: :strong_weekend_nights,
    oncology: :highland_weekend_days,
    highland_gynecology: :highland_weekend_nights
  }

  # Year-specific elective priority queues (in fill order)
  @year_electives %{
    1 => [:unknown, :swing, :highland_gynecology, :vacation, :elective, :float],
    2 => [:rei, :highland_gynecology, :vacation, :elective, :float],
    3 => [:urogynecology, :highland_gynecology, :vacation, :elective, :float],
    4 => [:highland_gynecology, :vacation, :elective, :float]
  }

  @doc """
  Generates a complete assignment map for the given residents and slots.

  Returns `%{{resident_index, slot_index} => rotation_type_atom}`.
  Only slots with actual assignments are present in the map.

      iex> alias ResidencySchedule.ScheduleBuilder.{ResidentRoster, SlotCalendar}
      iex> residents = ResidentRoster.build_residents()
      iex> slots = SlotCalendar.build_slots(2026)
      iex> assignments = ResidencySchedule.ScheduleBuilder.Generator.assign_all(residents, slots)
      iex> is_map(assignments)
      true
      iex> map_size(assignments) > 0
      true
  """
  def assign_all(residents, slots) do
    weekday_slots = Enum.filter(slots, & !&1.is_weekend)
    weekend_slots = Enum.filter(slots, & &1.is_weekend)

    queues = build_queues(residents)

    {assignments, _queues} = assign_backbone(weekday_slots, residents, queues)
    assignments = assign_electives(assignments, residents, weekday_slots)
    derive_weekend_coverage(assignments, residents, weekday_slots, weekend_slots)
  end

  # --- Private: round-robin queue initialization ---

  defp build_queues(residents) do
    Enum.flat_map(@backbone, fn {rotation_type, allowed_years} ->
      Enum.map(allowed_years, fn year ->
        indices =
          residents
          |> Enum.with_index()
          |> Enum.filter(fn {r, _} -> r.residency_year == year end)
          |> Enum.map(fn {_, i} -> i end)

        {{rotation_type, year}, :queue.from_list(indices)}
      end)
    end)
    |> Map.new()
  end

  # --- Private: backbone assignment with round-robin ---

  defp assign_backbone(weekday_slots, _residents, queues) do
    Enum.reduce(weekday_slots, {%{}, queues}, fn slot, {assignments, qs} ->
      Enum.reduce(@backbone, {assignments, qs}, fn {rotation_type, allowed_years}, {a, q} ->
        assign_backbone_slot(slot, rotation_type, allowed_years, a, q)
      end)
    end)
  end

  defp assign_backbone_slot(slot, rotation_type, allowed_years, assignments, queues) do
    already_assigned =
      assignments
      |> Enum.filter(fn {{_ri, si}, _t} -> si == slot.slot_index end)
      |> Enum.map(fn {{ri, _}, _} -> ri end)
      |> MapSet.new()

    Enum.reduce(allowed_years, {assignments, queues}, fn year, {a, q} ->
      queue_key = {rotation_type, year}
      queue = Map.get(q, queue_key, :queue.new())

      {res_idx, updated_queue} = dequeue_next(queue, already_assigned)

      if res_idx == nil do
        {a, q}
      else
        a2 = Map.put(a, {res_idx, slot.slot_index}, rotation_type)
        q2 = Map.put(q, queue_key, updated_queue)
        {a2, q2}
      end
    end)
  end

  # Dequeue the next resident not in the excluded set.
  # Skipped residents are re-enqueued at the back.
  defp dequeue_next(queue, excluded) do
    dequeue_next(queue, excluded, :queue.len(queue))
  end

  defp dequeue_next(_queue, _excluded, 0), do: {nil, :queue.new()}

  defp dequeue_next(queue, excluded, attempts_left) do
    case :queue.out(queue) do
      {{:value, res_idx}, rest} ->
        if res_idx in excluded do
          dequeue_next(:queue.in(res_idx, rest), excluded, attempts_left - 1)
        else
          {res_idx, :queue.in(res_idx, rest)}
        end

      {:empty, _} ->
        {nil, queue}
    end
  end

  # --- Private: elective fill ---

  defp assign_electives(assignments, residents, weekday_slots) do
    needs = build_needs_map(residents)

    {assignments, _needs} =
      residents
      |> Enum.with_index()
      |> Enum.reduce({assignments, needs}, fn {resident, res_idx}, {asgn, nds} ->
        fill_resident_electives(res_idx, resident.residency_year, weekday_slots, asgn, nds)
      end)

    assignments
  end

  defp fill_resident_electives(res_idx, residency_year, weekday_slots, assignments, needs) do
    priority = Map.get(@year_electives, residency_year, [:float])

    unassigned_slots =
      Enum.reject(weekday_slots, fn slot ->
        Map.has_key?(assignments, {res_idx, slot.slot_index})
      end)

    Enum.reduce(unassigned_slots, {assignments, needs}, fn slot, {asgn, nds} ->
      rotation_type = pick_elective(res_idx, residency_year, priority, nds)
      a2 = Map.put(asgn, {res_idx, slot.slot_index}, rotation_type)
      n2 = Map.update(nds, {res_idx, rotation_type}, 0, & max(&1 - 1, 0))
      {a2, n2}
    end)
  end

  defp pick_elective(res_idx, residency_year, priority, needs) do
    valid = ResidentRoster.valid_rotations_for_year(residency_year)

    Enum.find(priority, :float, fn rotation_type ->
      rotation_type in valid and Map.get(needs, {res_idx, rotation_type}, 0) > 0
    end)
  end

  # --- Private: weekend derivation ---

  defp derive_weekend_coverage(assignments, residents, weekday_slots, weekend_slots) do
    weekday_to_weekend =
      Enum.reduce(weekend_slots, %{}, fn we_slot, acc ->
        preceding =
          Enum.find(weekday_slots, fn wd -> wd.slot_index == we_slot.slot_index - 1 end)

        if preceding, do: Map.put(acc, preceding.slot_index, we_slot.slot_index), else: acc
      end)

    residents
    |> Enum.with_index()
    |> Enum.reduce(assignments, fn {_resident, res_idx}, asgn ->
      Enum.reduce(weekday_to_weekend, asgn, fn {wd_idx, we_idx}, a ->
        case Map.get(a, {res_idx, wd_idx}) do
          nil ->
            a

          rotation_type ->
            case Map.get(@weekend_map, rotation_type) do
              nil -> a
              weekend_type -> Map.put(a, {res_idx, we_idx}, weekend_type)
            end
        end
      end)
    end)
  end

  # --- Private: needs map (for elective fill) ---

  defp build_needs_map(residents) do
    residents
    |> Enum.with_index()
    |> Enum.flat_map(fn {resident, res_idx} ->
      targets = ResidentRoster.rotation_targets_for_year(resident.residency_year)
      Enum.map(targets, fn {rotation_type, count} -> {{res_idx, rotation_type}, count} end)
    end)
    |> Map.new()
  end
end
