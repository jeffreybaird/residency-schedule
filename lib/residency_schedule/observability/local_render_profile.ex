defmodule ResidencySchedule.Observability.LocalRenderProfile do
  @moduledoc """
  Explicit local render profiling, compiled out of production builds.

  Stage measurements preserve Phoenix's rendering pipeline, including lazy HEEx
  evaluation inside Diff.render. Optional eprof tracing selects only the calling
  process, excludes spawned processes, and owns and stops its profiling session.
  Reports contain local function aggregates, not arguments or rendered content.
  Nothing calls this helper during normal application operation.
  """

  @doc """
  Runs a local render pipeline and returns its output and stage durations.

  Pass `eprof: true` for an explicit local function profile. An existing profiler
  is left alone. Production builds return `{:error, :disabled}`. Successful use
  requires a mounted LiveView and is covered by integration tests.
  """
  def run(socket, fingerprints, components, options \\ [])

  if Mix.env() == :prod do
    def run(_, _, _, _), do: {:error, :disabled}
  else
    alias Phoenix.LiveView.{Diff, Lifecycle, Renderer, Utils}

    def run(socket, fingerprints, components, options) do
      fun = fn -> pipeline(socket, fingerprints, components) end
      if options[:eprof] == true, do: profile(fun), else: {:ok, fun.()}
    end

    defp pipeline(socket, fingerprints, components) do
      {rendered, to_rendered_ms} = measure(fn -> Renderer.to_rendered(socket, socket.view) end)

      {{diff, fingerprints, components}, diff_render_ms} =
        measure(fn -> Diff.render(socket, rendered, fingerprints, components) end)

      {socket, after_render_ms} = measure(fn -> Lifecycle.after_render(socket) end)

      {{socket, diff}, finalize_ms} =
        measure(fn ->
          socket = Utils.clear_changed(socket)
          diff = Diff.render_private(socket, diff)
          {Utils.clear_temp(socket), diff}
        end)

      %{
        socket: socket,
        diff: diff,
        fingerprints: fingerprints,
        components: components,
        measurements: %{
          to_rendered_ms: to_rendered_ms,
          diff_render_ms: diff_render_ms,
          after_render_ms: after_render_ms,
          finalize_ms: finalize_ms
        }
      }
    end

    defp measure(fun) do
      started = System.monotonic_time()
      result = fun.()

      {result,
       (System.monotonic_time() - started) / System.convert_time_unit(1, :millisecond, :native)}
    end

    defp profile(fun) do
      if Process.whereis(:eprof) do
        {:error, :already_running}
      else
        loaded_profile(fun)
      end
    end

    defp loaded_profile(fun) do
      with {:ok, added_path} <- load_tools() do
        try do
          own_profiler(fun, :eprof)
        after
          if added_path, do: :code.del_path(added_path)
        end
      end
    end

    defp own_profiler(fun, profiler) do
      # OTP tools is loaded only for this explicit local request.
      case profiler.start() do
        {:ok, _pid} ->
          try do
            :profiling =
              profiler.start_profiling([self()], {:_, :_, :_}, set_on_spawn: false)

            result = fun.()
            profiler.stop_profiling()
            profiler.analyze(:total, sort: :time)
            {:ok, result}
          after
            profiler.stop_profiling()
            profiler.stop()
          end

        {:error, {:already_started, _}} ->
          {:error, :already_running}

        {:error, _} ->
          {:error, :unavailable}
      end
    end

    defp load_tools do
      if Code.ensure_loaded?(:eprof) do
        {:ok, nil}
      else
        paths =
          :code.root_dir()
          |> List.to_string()
          |> Path.join("lib/tools-*/ebin")
          |> Path.wildcard()

        case paths do
          [path | _] ->
            path = String.to_charlist(path)
            true = :code.add_pathz(path)
            {:ok, path}

          [] ->
            {:error, :unavailable}
        end
      end
    end
  end
end
