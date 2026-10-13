defmodule ResidencySchedule.CountingJSON do
  @moduledoc false

  def encode_to_iodata!(value) do
    Process.put(:diagnostic_encode_calls, Process.get(:diagnostic_encode_calls, 0) + 1)
    Jason.encode_to_iodata!(value)
  end

  def decode!(value), do: Jason.decode!(value)
end
