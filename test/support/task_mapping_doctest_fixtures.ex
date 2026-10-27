defmodule ResidencySchedule.TaskMappingDoctestFixtures do
  @moduledoc "Explicit synthetic source occurrences for sandboxed task mapping examples."

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.IdentityMappingDoctestFixtures
  alias ResidencySchedule.Repo

  def source(raw_task \\ "SMH GYN R2 Day") do
    IdentityMappingDoctestFixtures.seed()
    |> add_source(raw_task)
  end

  def add_source(ctx, raw_task, options \\ []) do
    number = Keyword.get(options, :number, System.unique_integer([:positive]))
    date = Keyword.get(options, :date, Date.new!(ctx.schedule.academic_year, 12, 30))

    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: ctx.schedule.id,
        created_by_id: ctx.admin.id,
        fingerprint: "task-source-#{number}",
        source_kind: Keyword.get(options, :source_kind, "qgenda"),
        header_start: date,
        header_end: date
      })

    activity =
      Keyword.get_lazy(options, :activity, fn ->
        Repo.insert!(%Activity{
          schedule_resident_id: ctx.member.id,
          date: date,
          raw_task: raw_task,
          period: "PM",
          site: "SMH"
        })
      end)

    source =
      Repo.insert!(%ActivitySource{
        activity_id: activity.id,
        batch_id: batch.id,
        source_sheet: "December",
        source_cell: "D#{number}",
        raw_staff: "Reed, Iris",
        display_name: ctx.member.name,
        previous_name: ctx.member.name,
        notes: [%{"text" => "Preserve this note"}],
        source_reference: %{"sheet" => "December", "cell" => "D#{number}"}
      })

    Map.merge(ctx, %{source: source, activity: activity, batch: batch})
  end
end
