defmodule ResidencySchedule.ScheduleOrderingFixture do
  @moduledoc "Provides academic-year keys for the reverse-insertion ordering fixture."

  @doc """
  Returns the older and newer years used to verify ordering independently of insertion order.

      iex> {older, newer} = ResidencySchedule.ScheduleOrderingFixture.years()
      iex> newer > older
      true
  """
  def years do
    # The fixture tests integer ordering, not calendar dates. Reserve keys beyond
    # the fixed-year CSV fixtures so concurrent Sandbox transactions never share them.
    older = 10_000 + 2 * System.unique_integer([:positive, :monotonic])
    {older, older + 1}
  end
end
