defmodule ResidencySchedule.EffectiveSchedule.Normalize do
  @moduledoc """
  Normalizes effective segments into daily duty records.

  A daily record is the unit of comparison between schedule read versions
  (plan D1): one record per membership and date, with its duties sorted by a
  total order so two records compare by equality. This module is pure and
  never touches the database.
  """

  alias ResidencySchedule.Rotations

  @date_only %{precision: :date_only, period: nil}
  @off_types ~w(vacation leave_of_absence)

  @doc """
  Expands segments into one record per date of `range` for one membership.

  Days without a segment are blank records with no duties.

      iex> segment = %{
      ...>   rotation_type: "ambulatory",
      ...>   start_date: ~D[2026-07-07],
      ...>   end_date: ~D[2026-07-08],
      ...>   slot_index: 0,
      ...>   is_coverage: false,
      ...>   covered_by: nil,
      ...>   original_resident: nil,
      ...>   source_assignment_date: nil,
      ...>   source_tasks: []
      ...> }
      iex> membership = %{person_id: 1, schedule_resident_id: 2, schedule_id: 3}
      iex> range = Date.range(~D[2026-07-06], ~D[2026-07-07])
      iex> [blank, working] = ResidencySchedule.EffectiveSchedule.Normalize.daily_records([segment], membership, range)
      iex> {blank.off, working.off, hd(working.duties).code}
      {:blank, nil, "ambulatory"}
  """
  def daily_records(segments, membership, range) do
    Enum.map(range, &daily_record(segments, membership, &1))
  end

  @doc """
  Maps one effective segment to a duty.

      iex> segment = %{
      ...>   rotation_type: "qgenda_assignment",
      ...>   start_date: ~D[2026-07-21],
      ...>   end_date: ~D[2026-07-21],
      ...>   slot_index: -1,
      ...>   is_coverage: false,
      ...>   covered_by: nil,
      ...>   original_resident: nil,
      ...>   source_assignment_date: ~D[2026-07-21],
      ...>   source_tasks: ["Mystery Clinic PM"]
      ...> }
      iex> duty = ResidencySchedule.EffectiveSchedule.Normalize.duty_from_segment(segment)
      iex> {duty.kind, duty.label, duty.status}
      {:gap_fill, "Mystery Clinic PM", :working}
  """
  def duty_from_segment(segment) do
    %{
      kind: duty_kind(segment),
      code: segment.rotation_type,
      label: Rotations.assignment_label(segment),
      status: duty_status(segment),
      source_tasks: Map.get(segment, :source_tasks, []),
      timing: @date_only,
      covered_by_person_id: person_id(segment.covered_by),
      original_person_id: person_id(segment.original_resident),
      source_assignment_date: Map.get(segment, :source_assignment_date)
    }
  end

  @doc """
  Sorts duties by kind, code, status, source date, tasks and the people involved.

  Dates compare chronologically with nil first.

      iex> alias ResidencySchedule.EffectiveSchedule.Normalize
      iex> base = %{
      ...>   kind: :rotation,
      ...>   code: "ambulatory",
      ...>   label: "Ambulatory",
      ...>   status: :working,
      ...>   source_tasks: [],
      ...>   timing: %{precision: :date_only, period: nil},
      ...>   covered_by_person_id: nil,
      ...>   original_person_id: nil,
      ...>   source_assignment_date: nil
      ...> }
      iex> coverage = %{base | kind: :coverage, code: "night_float", original_person_id: 9}
      iex> Normalize.sort_duties([base, coverage]) |> Enum.map(& &1.kind)
      [:coverage, :rotation]
  """
  def sort_duties(duties) do
    Enum.sort_by(duties, &sort_key/1)
  end

  @doc """
  Derives the day's off state from its duties.

      iex> alias ResidencySchedule.EffectiveSchedule.Normalize
      iex> Normalize.off_state([%{code: "vacation", status: :off}])
      :vacation

      iex> alias ResidencySchedule.EffectiveSchedule.Normalize
      iex> Normalize.off_state([%{code: "ambulatory", status: :working}])
      nil
  """
  def off_state([]), do: :blank

  def off_state(duties) do
    cond do
      Enum.any?(duties, &(&1.code == "vacation")) -> :vacation
      Enum.any?(duties, &(&1.code == "leave_of_absence")) -> :leave
      true -> nil
    end
  end

  defp daily_record(segments, membership, date) do
    duties =
      segments
      |> Enum.filter(&covers_date?(&1, date))
      |> Enum.map(&duty_from_segment/1)
      |> sort_duties()

    membership
    |> Map.take([:person_id, :schedule_resident_id, :schedule_id])
    |> Map.merge(%{date: date, duties: duties, off: off_state(duties)})
  end

  defp covers_date?(segment, date) do
    Date.compare(segment.start_date, date) != :gt and
      Date.compare(segment.end_date, date) != :lt
  end

  defp duty_kind(%{is_coverage: true}), do: :coverage
  defp duty_kind(%{slot_index: -1}), do: :gap_fill
  defp duty_kind(_segment), do: :rotation

  defp duty_status(%{covered_by: covered_by}) when not is_nil(covered_by), do: :covered
  defp duty_status(%{rotation_type: type}) when type in @off_types, do: :off
  defp duty_status(_segment), do: :working

  defp person_id(nil), do: nil
  defp person_id(%{resident_id: id}), do: id

  defp sort_key(duty) do
    {duty.kind, duty.code, duty.status, nil_first(duty.source_assignment_date), duty.source_tasks,
     nil_first(duty.covered_by_person_id), nil_first(duty.original_person_id)}
  end

  defp nil_first(nil), do: {0, 0}
  defp nil_first(%Date{} = date), do: {1, Date.to_gregorian_days(date)}
  defp nil_first(value), do: {1, value}
end
