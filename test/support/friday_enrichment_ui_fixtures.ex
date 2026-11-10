defmodule ResidencySchedule.FridayEnrichmentUIFixtures do
  @moduledoc "Targeted cleanup for the one committed background-job integration fixture."

  alias ResidencySchedule.Repo
  alias ResidencySchedule.TaskMappings.FridayEnrichmentRunner

  @tables ~w(friday_policy_attestations activity_source_timings source_identity_mappings activity_source_classifications detailed_activity_sources detailed_activities detailed_import_batches source_task_mappings activity_types schedule_residents residents schedules users)

  def baseline do
    Map.new(@tables, &{&1, ids(&1)})
  end

  def cleanup(baseline) do
    mapping_ids = ids("source_task_mappings") -- Map.fetch!(baseline, "source_task_mappings")

    for table <- @tables do
      if table == "source_task_mappings" do
        Repo.query!(
          "DELETE FROM source_task_mapping_targets WHERE mapping_id=ANY($1::bigint[])",
          [mapping_ids]
        )
      end

      added = ids(table) -- Map.fetch!(baseline, table)
      Repo.query!("DELETE FROM #{table} WHERE id=ANY($1::bigint[])", [added])
    end
  end

  def await_terminal(user) do
    Phoenix.PubSub.subscribe(ResidencySchedule.PubSub, "maintenance:friday-policy")
    wait_for_run(user)
  end

  def await_workers do
    supervisor = ResidencySchedule.TaskMappings.FridayEnrichmentTaskSupervisor

    if Process.whereis(supervisor) do
      for pid <- Task.Supervisor.children(supervisor) do
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> raise "Friday worker remained active during fixture cleanup"
        end
      end
    end

    :ok
  end

  defp wait_for_run(user) do
    {:ok, %{run: run}} = FridayEnrichmentRunner.status(user)

    if run.status == :running do
      receive do
        :friday_policy_enrichment_status_changed -> wait_for_run(user)
      after
        5_000 -> raise "Friday enrichment did not finish before fixture teardown"
      end
    else
      run
    end
  end

  defp ids(table), do: Repo.query!("SELECT id FROM #{table} ORDER BY id").rows |> Enum.map(&hd/1)
end
