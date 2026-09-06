defmodule ResidencySchedule.Assistant.LocalDate do
  @moduledoc """
  Date handling for assistant questions. "Today" means today in the program's
  local time zone (America/New_York), not UTC — the two differ every evening.
  """

  @time_zone "America/New_York"

  @doc """
  Returns the program's IANA time zone.

      iex> ResidencySchedule.Assistant.LocalDate.time_zone()
      "America/New_York"
  """
  def time_zone, do: @time_zone

  @doc """
  Converts a UTC datetime to the local calendar date.

      iex> ResidencySchedule.Assistant.LocalDate.to_local_date(~U[2026-09-07 02:30:00Z])
      ~D[2026-09-06]

      iex> ResidencySchedule.Assistant.LocalDate.to_local_date(~U[2026-01-07 02:30:00Z])
      ~D[2026-01-06]

      iex> ResidencySchedule.Assistant.LocalDate.to_local_date(~U[2026-09-06 12:00:00Z])
      ~D[2026-09-06]
  """
  def to_local_date(%DateTime{} = utc) do
    utc
    |> DateTime.shift_zone!(@time_zone)
    |> DateTime.to_date()
  end

  @doc """
  Today's local date.

  Exempt from doctest — depends on the clock.
  """
  def today, do: to_local_date(DateTime.utc_now())

  @doc """
  Parses an optional ISO 8601 date argument. `nil` and `""` mean today.

      iex> ResidencySchedule.Assistant.LocalDate.parse("2026-09-06")
      {:ok, ~D[2026-09-06]}

      iex> ResidencySchedule.Assistant.LocalDate.parse("tomorrow")
      {:error, :invalid_date}
  """
  def parse(nil), do: {:ok, today()}
  def parse(""), do: {:ok, today()}

  def parse(text) when is_binary(text) do
    case Date.from_iso8601(String.trim(text)) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :invalid_date}
    end
  end

  def parse(_other), do: {:error, :invalid_date}

  @doc """
  Parses an optional date that may be absent, returning `{:ok, nil}` when so.

      iex> ResidencySchedule.Assistant.LocalDate.parse_optional(nil)
      {:ok, nil}

      iex> ResidencySchedule.Assistant.LocalDate.parse_optional("2026-12-31")
      {:ok, ~D[2026-12-31]}
  """
  def parse_optional(nil), do: {:ok, nil}
  def parse_optional(""), do: {:ok, nil}
  def parse_optional(text), do: parse(text)
end
