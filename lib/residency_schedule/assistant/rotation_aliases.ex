defmodule ResidencySchedule.Assistant.RotationAliases do
  @moduledoc """
  Maps the shorthand people actually say ("strong ob", "onc", "NF") to the
  rotation type strings stored in the database.
  """

  @aliases %{
    "strong_obstetrics" => [
      "ob",
      "obs",
      "l&d",
      "labor and delivery",
      "strong ob",
      "strong obs",
      "strong obstetrics",
      "obstetrics",
      "strong l&d",
      "sob"
    ],
    "highland_obstetrics" => ["highland ob", "highland obs", "highland obstetrics", "hhob", "hob"],
    "oncology" => ["onc", "gyn onc", "gynonc", "oncology", "gyn oncology"],
    "strong_gynecology" => ["gyn", "strong gyn", "gynecology", "strong gynecology", "benign gyn"],
    "highland_gynecology" => ["highland gyn", "highland gynecology", "hgyn"],
    "night_float" => [
      "nf",
      "night float",
      "nights",
      "strong nf",
      "strong night float",
      "strong nights"
    ],
    "highland_night_float" => ["highland nf", "highland night float", "highland nights", "hnf"],
    "ambulatory" => ["amb", "ambulatory", "clinic"],
    "rei" => ["rei", "reproductive endocrinology", "infertility"],
    "urogynecology" => ["urogyn", "urogynecology", "uro gyn", "urology"],
    "elective" => ["elective"],
    "swing" => ["swing", "swing shift"],
    "ultrasound" => ["ultrasound", "us", "u/s"],
    "vacation" => ["vacation", "vaca", "vacay", "off"],
    "post_call" => ["post call", "postcall", "pc"],
    "float" => ["float"],
    "away_rotation" => ["away", "away rotation"],
    "strong_weekend_days" => ["swd", "strong weekend days", "weekend days"],
    "strong_weekend_nights" => ["swn", "strong weekend nights", "weekend nights"],
    "highland_weekend_days" => ["hwd", "highland weekend days"],
    "highland_weekend_nights" => ["hwn", "highland weekend nights"]
  }

  @lookup Enum.reduce(@aliases, %{}, fn {type, names}, acc ->
            acc
            |> Map.put(type, type)
            |> Map.merge(Map.new(names, &{&1, type}))
          end)

  @weekend_counterparts %{
    "strong_obstetrics" => ["strong_weekend_days", "strong_weekend_nights"],
    "strong_gynecology" => ["strong_weekend_days", "strong_weekend_nights"],
    "oncology" => ["strong_weekend_days", "strong_weekend_nights"],
    "night_float" => ["strong_weekend_nights"],
    "highland_obstetrics" => ["highland_weekend_days", "highland_weekend_nights"],
    "highland_gynecology" => ["highland_weekend_days", "highland_weekend_nights"],
    "highland_night_float" => ["highland_weekend_nights"]
  }

  @doc """
  Resolves free text to a rotation type string. Matching is case-insensitive
  and ignores punctuation and repeated whitespace.

      iex> ResidencySchedule.Assistant.RotationAliases.resolve("Strong OB")
      {:ok, "strong_obstetrics"}

      iex> ResidencySchedule.Assistant.RotationAliases.resolve("night-float")
      {:ok, "night_float"}

      iex> ResidencySchedule.Assistant.RotationAliases.resolve("oncology")
      {:ok, "oncology"}

      iex> ResidencySchedule.Assistant.RotationAliases.resolve("dermatology")
      {:error, :unknown_rotation}
  """
  def resolve(text) when is_binary(text) do
    key = normalize(text)

    case Map.get(@lookup, key) || Map.get(@lookup, String.replace(key, " ", "_")) do
      nil -> {:error, :unknown_rotation}
      type -> {:ok, type}
    end
  end

  def resolve(_text), do: {:error, :unknown_rotation}

  @doc """
  Weekend rotation types that stand in for a weekday service on Saturdays and
  Sundays. Empty for services that have no weekend counterpart.

      iex> ResidencySchedule.Assistant.RotationAliases.weekend_counterparts("strong_obstetrics")
      ["strong_weekend_days", "strong_weekend_nights"]

      iex> ResidencySchedule.Assistant.RotationAliases.weekend_counterparts("ambulatory")
      []
  """
  def weekend_counterparts(rotation_type), do: Map.get(@weekend_counterparts, rotation_type, [])

  @doc """
  Normalizes user text for alias lookup: lowercase, punctuation other than
  `&` and `/` stripped, whitespace collapsed.

      iex> ResidencySchedule.Assistant.RotationAliases.normalize("  Strong-OB! ")
      "strong ob"
  """
  def normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9&\/\s]/u, " ")
    |> String.split()
    |> Enum.join(" ")
  end
end
