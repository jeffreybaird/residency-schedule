defmodule ResidencySchedule.Rotations.HighlandPostCall do
  @moduledoc "Reconciles Post Call with the resident's baseline Highland Night Float."

  @doc """
  Removes a resident's Highland Night Float dates from their Post Call spans.

  Remaining spans retain the original assignment fields and identity. Inputs
  without resident IDs belong to a single parsed resident. Coverage assignments
  must be applied after normalization so they cannot remove another resident's
  Post Call.

      iex> alias ResidencySchedule.Rotations.HighlandPostCall
      iex> post_call = %{rotation_type: :post_call, start_date: ~D[2026-11-07], end_date: ~D[2026-11-08], slot_index: 0}
      iex> hnf = %{rotation_type: :highland_night_float, start_date: ~D[2026-11-08], end_date: ~D[2026-11-13], slot_index: 1}
      iex> [remaining, night] = HighlandPostCall.normalize([post_call, hnf])
      iex> {remaining.start_date, remaining.end_date, night == hnf}
      {~D[2026-11-07], ~D[2026-11-07], true}
  """
  def normalize(rotations) do
    nights_by_resident =
      rotations
      |> Enum.filter(&(&1.rotation_type in [:highland_night_float, "highland_night_float"]))
      |> Enum.group_by(&Map.get(&1, :schedule_resident_id))

    Enum.flat_map(rotations, &subtract_own_nights(&1, nights_by_resident))
  end

  defp subtract_own_nights(%{rotation_type: type} = rotation, nights_by_resident)
       when type in [:post_call, "post_call"] do
    nights_by_resident
    |> Map.get(Map.get(rotation, :schedule_resident_id), [])
    |> Enum.reduce([rotation], fn night, remaining ->
      Enum.flat_map(remaining, &subtract_night(&1, night))
    end)
  end

  defp subtract_own_nights(rotation, _nights_by_resident), do: [rotation]

  defp subtract_night(post_call, night) do
    if Date.compare(night.start_date, post_call.end_date) == :gt or
         Date.compare(night.end_date, post_call.start_date) == :lt do
      [post_call]
    else
      remaining_before(post_call, night) ++ remaining_after(post_call, night)
    end
  end

  defp remaining_before(post_call, night) do
    if Date.compare(post_call.start_date, night.start_date) == :lt do
      [%{post_call | end_date: Date.add(night.start_date, -1)}]
    else
      []
    end
  end

  defp remaining_after(post_call, night) do
    if Date.compare(post_call.end_date, night.end_date) == :gt do
      [%{post_call | start_date: Date.add(night.end_date, 1)}]
    else
      []
    end
  end
end
