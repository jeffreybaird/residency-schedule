# Explicit local-only profiling against the same disposable synthetic four-year
# fixture as schedule_cache.exs. No profiler starts with the application.
# SCHEDULE_BENCHMARK_DATABASE=residency_schedule_cache_bench_<suffix> \
#   MIX_ENV=test mix run --no-start test/support/benchmarks/render_diagnostics.exs
# Add RENDER_EPROF=true to profile this process during each sampled stage run.
Code.require_file("schedule_cache.exs", __DIR__)

alias Phoenix.LiveView.{Diff, Lifecycle}
alias ResidencySchedule.Observability.LocalRenderProfile
alias ResidencyScheduleWeb.{Endpoint, ScheduleLive.Index}

socket = %Phoenix.LiveView.Socket{
  view: Index,
  endpoint: Endpoint,
  transport_pid: self(),
  private: %{live_layout: false, live_temp: %{}, lifecycle: Lifecycle.build([])},
  assigns: %{
    __changed__: %{},
    current_user: %ResidencySchedule.Accounts.User{role: :resident, tour_completed: true}
  }
}

{:ok, socket} = Index.mount(%{}, %{}, socket)
options = [eprof: System.get_env("RENDER_EPROF") == "true"]

{_, _, _} =
  Enum.reduce(
    [:initial, :unchanged, :filter_year],
    {socket, Diff.new_fingerprints(), Diff.new_components()},
    fn stage, {socket, fingerprints, components} ->
      socket =
        if stage == :filter_year do
          {:noreply, updated} = Index.handle_event("filter_year", %{"year" => "2"}, socket)
          updated
        else
          socket
        end

      {:ok, result} = LocalRenderProfile.run(socket, fingerprints, components, options)

      IO.puts(
        Jason.encode!(%{
          render_stage: stage,
          measurements: result.measurements,
          encoded_diff_bytes: result.diff |> Jason.encode_to_iodata!() |> IO.iodata_length(),
          empty_diff: result.diff == %{}
        })
      )

      if stage == :unchanged and result.diff != %{}, do: raise("unchanged render emitted a diff")
      {result.socket, result.fingerprints, result.components}
    end
  )
