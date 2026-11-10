defmodule ResidencyScheduleWeb.AdminLive.FridayPolicyBackgroundTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias ResidencySchedule.FridayEnrichmentFixtures, as: Fixtures
  alias ResidencySchedule.FridayEnrichmentUIFixtures
  alias ResidencySchedule.Repo
  alias ResidencySchedule.ScheduleFixtures
  alias ResidencySchedule.TaskMappings.FridayEnrichmentRunner

  @endpoint ResidencyScheduleWeb.Endpoint
  @path "/admin/maintenance/friday-policy"

  setup do
    expected = Keyword.fetch!(Repo.config(), :database)

    actual =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[database]]} = Repo.query!("SELECT current_database()")
        database
      end)

    assert actual == expected
    assert String.starts_with?(actual, "residency_schedule_test")
    ResidencySchedule.DataCase.set_chat_enabled(false)

    # Independent process connections are required to inspect status and revoke an
    # actor while the real application-owned worker waits on a database lock.
    :ok = Sandbox.mode(Repo, :auto)
    baseline = FridayEnrichmentUIFixtures.baseline()

    on_exit(fn ->
      try do
        FridayEnrichmentUIFixtures.await_workers()
        FridayEnrichmentUIFixtures.cleanup(baseline)
      after
        Sandbox.mode(Repo, :manual)
      end
    end)

    :ok
  end

  test "one node-owned job survives leaving the page and deferred preview delivery rechecks access" do
    ctx = Fixtures.historical_source()
    other = ScheduleFixtures.admin_user()
    :ok = Phoenix.PubSub.subscribe(ResidencySchedule.PubSub, "maintenance:friday-policy")
    conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(user_id: ctx.admin.id)
    other_conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(user_id: other.id)
    assert {:ok, view, _} = live(conn, @path)
    view |> element("#friday-policy-preview") |> render_click()
    render_async(view, 5_000)

    opts =
      Keyword.take(Repo.config(), [
        :hostname,
        :port,
        :username,
        :password,
        :database,
        :socket_dir,
        :ssl
      ])

    {:ok, locker} = Postgrex.start_link(opts)

    try do
      lock_attestations(locker)
      view |> element("#friday-policy-apply") |> render_click()
      await_blocked_worker(locker)

      assert {:ok, %{run: %{operation: :apply, status: :running}}} =
               FridayEnrichmentRunner.status(other)

      assert {:error, :busy} = FridayEnrichmentRunner.preview(other)
      assert {:error, :busy} = FridayEnrichmentRunner.start(other, "another-session")
      ref = Process.monitor(view.pid)
      {_proxy_ref, _topic, proxy_pid} = view.proxy
      Process.unlink(proxy_pid)
      Process.unlink(view.pid)
      Process.exit(view.pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed}, 5_000
      assert {:ok, other_view, _} = live(other_conn, @path)
      assert render(other_view) =~ "Enrichment in progress"
      Postgrex.query!(locker, "COMMIT", [])
      run = await_terminal(other)
      assert run.status == :completed
      assert run.counts.attested == 1
      assert run.finished_at != nil
      refute render(other_view) =~ ctx.member.name
      assert {:ok, status} = FridayEnrichmentRunner.status(other)
      assert status.last_run == run
      FridayEnrichmentUIFixtures.await_workers()

      lock_attestations(locker)
      preview = Task.async(fn -> FridayEnrichmentRunner.preview(ctx.admin) end)
      await_blocked_worker(locker)

      assert {:ok, %{run: %{operation: :preview, status: :running}}} =
               FridayEnrichmentRunner.status(other)

      Repo.update!(Ecto.Changeset.change(ctx.admin, role: :user))
      Postgrex.query!(locker, "COMMIT", [])
      assert Task.await(preview, 5_000) == {:error, :forbidden}
      assert {:ok, status} = FridayEnrichmentRunner.status(other)
      assert status.run.status == :failed
      assert status.run.error == :forbidden
      assert status.preview == nil
      assert status.last_run == run
    after
      Postgrex.query(locker, "ROLLBACK", [])
      GenServer.stop(locker)
    end
  end

  defp lock_attestations(locker) do
    Postgrex.query!(locker, "BEGIN", [])
    Postgrex.query!(locker, "LOCK TABLE friday_policy_attestations IN ACCESS EXCLUSIVE MODE", [])
  end

  defp await_blocked_worker(locker) do
    %{rows: [[pid]]} = Postgrex.query!(locker, "SELECT pg_backend_pid()", [])
    await_database_wait(locker, pid, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_database_wait(locker, pid, deadline) do
    %{rows: [[waiting]]} =
      Postgrex.query!(
        locker,
        "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND $1=ANY(pg_blocking_pids(pid)))",
        [pid]
      )

    cond do
      waiting ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Application worker did not reach the database barrier")

      true ->
        await_database_wait(locker, pid, deadline)
    end
  end

  defp await_terminal(user) do
    assert {:ok, %{run: run}} = FridayEnrichmentRunner.status(user)

    if run.status == :running do
      receive do
        :friday_policy_enrichment_status_changed -> await_terminal(user)
      after
        5_000 -> flunk("Application-owned Friday job did not finish")
      end
    else
      run
    end
  end
end
