defmodule ResidencyScheduleWeb.LocalRenderProfileTest do
  use ResidencyScheduleWeb.ConnCase, async: false

  alias Phoenix.LiveView.{Diff, Lifecycle, Renderer, Utils}
  alias ResidencySchedule.Observability.LocalRenderProfile
  alias ResidencySchedule.ScheduleFixtures
  alias ResidencyScheduleWeb.{Endpoint, ScheduleLive.Index}

  setup do
    ScheduleFixtures.seed_mini_schedule()

    socket = %Phoenix.LiveView.Socket{
      view: Index,
      transport_pid: self(),
      endpoint: Endpoint,
      private: %{live_layout: false, live_temp: %{}, lifecycle: Lifecycle.build([])},
      assigns: %{
        __changed__: %{},
        current_user: %ResidencySchedule.Accounts.User{role: :resident, tour_completed: true}
      }
    }

    {:ok, socket} = Index.mount(%{}, %{}, socket)
    %{socket: socket}
  end

  test "explicit profiling preserves full pipeline output and reports separate stages", %{
    socket: socket
  } do
    fingerprints = Diff.new_fingerprints()
    components = Diff.new_components()
    rendered = Renderer.to_rendered(socket, Index)

    {diff, next_fingerprints, next_components} =
      Diff.render(socket, rendered, fingerprints, components)

    expected_socket = socket |> Lifecycle.after_render() |> Utils.clear_changed()
    expected_diff = Diff.render_private(expected_socket, diff)
    expected_socket = Utils.clear_temp(expected_socket)

    assert {:ok, result} = LocalRenderProfile.run(socket, fingerprints, components)
    assert result.socket == expected_socket
    assert result.diff == expected_diff
    assert result.fingerprints == next_fingerprints
    assert result.components == next_components

    assert Enum.sort(Map.keys(result.measurements)) ==
             Enum.sort(~w(to_rendered_ms diff_render_ms after_render_ms finalize_ms)a)

    for {_stage, milliseconds} <- result.measurements do
      assert is_number(milliseconds) and milliseconds >= 0
    end

    assert {:ok, next} =
             LocalRenderProfile.run(result.socket, result.fingerprints, result.components)

    assert next.diff == %{}
    refute Process.whereis(:eprof)
  end

  test "optional eprof owns and cleans its session even when rendering raises", %{socket: socket} do
    refute Process.whereis(:eprof)

    assert {:ok, _} =
             LocalRenderProfile.run(socket, Diff.new_fingerprints(), Diff.new_components(),
               eprof: true
             )

    refute Process.whereis(:eprof)
    broken = %{socket | assigns: Map.delete(socket.assigns, :all_slots)}

    assert_raise KeyError, fn ->
      LocalRenderProfile.run(broken, Diff.new_fingerprints(), Diff.new_components(), eprof: true)
    end

    refute Process.whereis(:eprof)
  end

  test "profiling refuses to take over an existing profiler", %{socket: socket} do
    [tools_path] =
      Path.wildcard(Path.join([List.to_string(:code.root_dir()), "lib", "tools-*", "ebin"]))

    :code.add_pathz(String.to_charlist(tools_path))
    {:ok, profiler} = :eprof.start()
    on_exit(fn -> if Process.alive?(profiler), do: :eprof.stop() end)

    assert {:error, :already_running} =
             LocalRenderProfile.run(socket, Diff.new_fingerprints(), Diff.new_components(),
               eprof: true
             )

    assert Process.whereis(:eprof) == profiler
  end

  test "owned profiler has exited before success, failure and immediate reuse return", %{
    socket: socket
  } do
    for outcome <- [:success, :raise, :success] do
      tag = make_ref()

      tracked_socket =
        Phoenix.LiveView.attach_hook(
          socket,
          :track_owned_profiler,
          :after_render,
          fn rendered_socket ->
            profiler = Process.whereis(:eprof)
            monitor = Process.monitor(profiler)
            send(self(), {tag, profiler, monitor})

            if outcome == :raise, do: raise("synthetic profiling pipeline failure")
            rendered_socket
          end
        )

      profile = fn ->
        LocalRenderProfile.run(tracked_socket, Diff.new_fingerprints(), Diff.new_components(),
          eprof: true
        )
      end

      if outcome == :raise do
        assert_raise RuntimeError, "synthetic profiling pipeline failure", profile
      else
        assert {:ok, _result} = profile.()
      end

      assert_received {^tag, profiler, monitor}
      refute Process.whereis(:eprof)
      assert_received {:DOWN, ^monitor, :process, ^profiler, :normal}
    end
  end
end
