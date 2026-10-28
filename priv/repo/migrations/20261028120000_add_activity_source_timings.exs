defmodule ResidencySchedule.Repo.Migrations.AddActivitySourceTimings do
  use Ecto.Migration

  def up, do: Enum.each(up_sql(), &execute/1)
  def down, do: Enum.each(down_sql(), &execute/1)

  @doc """
  Returns the additive timing precision representation for saved source occurrences.

      iex> ResidencySchedule.Repo.Migrations.AddActivitySourceTimings.up_sql()
      ...> |> Enum.any?(&(&1 =~ "CREATE TABLE activity_source_timings"))
      true
  """
  def up_sql do
    [
      """
      CREATE TABLE activity_source_timings (
        id bigserial PRIMARY KEY,
        original_source_id bigint NOT NULL UNIQUE CHECK (original_source_id > 0),
        activity_source_id bigint REFERENCES detailed_activity_sources(id) ON DELETE SET NULL,
        namespace text NOT NULL CHECK (namespace IN ('csv','qgenda')),
        source_date date NOT NULL,
        precision text NOT NULL CHECK (precision IN ('exact','period','date_only')),
        period text CHECK (period IN ('AM','PM','Day','Night')),
        starts_at timestamp with time zone,
        ends_at timestamp with time zone,
        time_zone text CHECK (octet_length(time_zone) BETWEEN 1 AND 64),
        source_snapshot jsonb NOT NULL,
        input_digest text NOT NULL,
        rule_version text NOT NULL,
        policy text NOT NULL CHECK (policy IN ('stored_period','date_only','exact_source')),
        evidence_origin text NOT NULL CHECK (evidence_origin IN ('legacy_code','reviewed','custom')),
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        CONSTRAINT activity_source_timing_live_source CHECK (
          activity_source_id IS NULL OR activity_source_id=original_source_id
        ),
        CONSTRAINT activity_source_timing_precision_shape CHECK (
          (precision='exact' AND starts_at IS NOT NULL AND ends_at IS NOT NULL AND
            time_zone IS NOT NULL AND starts_at < ends_at AND period IS NULL) OR
          (precision='period' AND period IS NOT NULL AND starts_at IS NULL AND
            ends_at IS NULL AND time_zone IS NULL) OR
          (precision='date_only' AND period IS NULL AND starts_at IS NULL AND
            ends_at IS NULL AND time_zone IS NULL)
        )
      )
      """,
      "CREATE INDEX activity_source_timing_live_index ON activity_source_timings(activity_source_id)"
    ]
  end

  @doc """
  Removes only the additive timing representation.

      iex> ResidencySchedule.Repo.Migrations.AddActivitySourceTimings.down_sql()
      ["DROP TABLE activity_source_timings"]
  """
  def down_sql do
    ["DROP TABLE activity_source_timings"]
  end
end
