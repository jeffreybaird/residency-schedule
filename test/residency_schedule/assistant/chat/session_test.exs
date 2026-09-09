defmodule ResidencySchedule.Assistant.Chat.SessionTest do
  # Sessions are registered globally by user id and the idle test changes
  # application config, so this module does not run alongside others.
  use ResidencySchedule.DataCase, async: false

  alias ResidencySchedule.Accounts
  alias ResidencySchedule.Assistant.Chat
  alias ResidencySchedule.Assistant.Chat.{Providers.Fake, Quota, Session, ToolCall}
  alias ResidencySchedule.Assistant.LocalDate

  doctest Session

  setup do
    {:ok, user} =
      Accounts.create_user(%{
        email: "session-#{System.unique_integer([:positive])}@urmc.rochester.edu"
      })

    :ok = Session.subscribe(user)
    on_exit(fn -> stop_session(user) end)
    %{user: user}
  end

  defp stop_session(user) do
    case Session.whereis(user) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  # Waits for the turn started by the last request to finish.
  defp await_idle do
    assert_receive {:chat_session, %{busy: false} = view}, 2_000
    view
  end

  describe "state/1" do
    test "starts a session with an empty transcript and today's quota", %{user: user} do
      assert Session.whereis(user) == nil

      assert %{entries: [], busy: false, pending: [], error: nil, remaining: remaining} =
               Session.state(user)

      assert remaining == Chat.daily_limit()
      assert is_pid(Session.whereis(user))
    end

    test "returns the same session on a second call", %{user: user} do
      Session.state(user)
      pid = Session.whereis(user)
      Session.state(user)
      assert Session.whereis(user) == pid
    end
  end

  describe "send/2" do
    test "runs a turn and broadcasts the transcript as it grows", %{user: user} do
      Fake.script([{:text, "Nora is on onc."}])

      assert :ok = Session.send(user, "Who is on onc?")

      assert_receive {:chat_session,
                      %{busy: true, entries: [%{kind: :user, text: "Who is on onc?"}]}}

      view = await_idle()
      assert [%{kind: :user}, %{kind: :assistant, text: "Nora is on onc."}] = view.entries
      assert view.remaining == Chat.daily_limit() - 1
      assert view.error == nil
    end

    test "trims the message and refuses a blank one", %{user: user} do
      assert {:error, :empty} = Session.send(user, "   ")
      assert Session.state(user).entries == []
      assert Session.state(user).remaining == Chat.daily_limit()
    end

    test "refuses a second message while a turn is running", %{user: user} do
      Fake.script([
        fn _request ->
          Process.sleep(150)
          {:text, "Late."}
        end
      ])

      assert :ok = Session.send(user, "First")
      assert {:error, :busy} = Session.send(user, "Second")
      assert {:error, :busy} = Session.reset(user)
      assert {:error, :busy} = Session.approve(user)

      view = await_idle()
      assert [%{text: "First"}, %{text: "Late."}] = view.entries
    end

    test "stops at the daily limit and says so in the view", %{user: user} do
      today = LocalDate.today()
      for _ <- 1..Chat.daily_limit(), do: {:ok, _} = Quota.consume(user, today)

      assert {:error, :limit_reached} = Session.send(user, "Hi")
      assert_receive {:chat_session, %{error: :limit_reached, remaining: 0, entries: []}}
    end

    test "keeps the conversation usable after a provider error", %{user: user} do
      Fake.script([{:error, {:transport, :timeout}}, {:text, "Back."}])

      :ok = Session.send(user, "Hi")
      assert %{error: {:transport, :timeout}} = await_idle()

      :ok = Session.send(user, "Again")
      view = await_idle()
      assert view.error == nil
      assert %{text: "Back."} = List.last(view.entries)
    end

    test "reports and logs a crash inside the turn", %{user: user} do
      Fake.script([fn _request -> raise "boom" end, {:text, "Recovered."}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok = Session.send(user, "Hi")
          assert %{error: :crashed} = await_idle()
        end)

      assert log =~ "chat turn crashed"
      assert log =~ "boom"

      :ok = Session.send(user, "Again")
      assert %{error: nil, entries: entries} = await_idle()
      assert %{text: "Recovered."} = List.last(entries)
    end
  end

  describe "approval" do
    setup do
      seed_schedule(2026)
      :ok
    end

    test "pauses on a mutating tool until approved", %{user: user} do
      call =
        ToolCall.new("toolu_1", "request_coverage", %{
          "covering" => "Nora",
          "start_date" => "2026-07-15"
        })

      Fake.script([{:tool_calls, "I will file it.", [call]}, {:text, "Filed."}])

      :ok = Session.send(user, "Cover me")
      assert %{pending: [^call]} = await_idle()

      assert :ok = Session.approve(user)
      view = await_idle()
      assert view.pending == []

      assert %{kind: :tool, result: %{error?: true}} =
               Enum.find(view.entries, &(&1.kind == :tool))

      assert %{text: "Filed."} = List.last(view.entries)
    end

    test "denying tells the model", %{user: user} do
      call = ToolCall.new("toolu_1", "cancel_change_request", %{"request_id" => 1})
      Fake.script([{:tool_calls, nil, [call]}, {:text, "Understood."}])

      :ok = Session.send(user, "Cancel it")
      assert %{pending: [_]} = await_idle()

      assert :ok = Session.deny(user)
      view = await_idle()
      assert view.pending == []

      assert %{kind: :tool, result: %{error?: true, content: content}} =
               Enum.find(view.entries, &(&1.kind == :tool))

      assert content =~ "declined"
    end

    test "there is nothing to decide without a pending call", %{user: user} do
      assert {:error, :nothing_pending} = Session.approve(user)
      assert {:error, :nothing_pending} = Session.deny(user)
    end
  end

  describe "reset/1" do
    test "clears the transcript but not the quota", %{user: user} do
      Fake.script([{:text, "Hello."}])
      :ok = Session.send(user, "Hi")
      await_idle()

      assert :ok = Session.reset(user)
      assert_receive {:chat_session, %{entries: [], error: nil, remaining: remaining}}
      assert remaining == Chat.daily_limit() - 1
    end
  end

  describe "lifetime" do
    test "an idle session stops after the configured time", %{user: user} do
      set_chat_idle_ms(50)
      Session.state(user)
      pid = Session.whereis(user)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert Session.whereis(user) == nil
    end

    test "a busy session does not time out", %{user: user} do
      set_chat_idle_ms(20)

      Fake.script([
        fn _request ->
          Process.sleep(120)
          {:text, "Slow."}
        end
      ])

      :ok = Session.send(user, "Hi")
      pid = Session.whereis(user)
      await_idle()
      assert Process.alive?(pid)
    end

    test "a second widget sees the same conversation", %{user: user} do
      Fake.script([{:text, "Hello."}])
      :ok = Session.send(user, "Hi")
      await_idle()

      assert [%{text: "Hi"}, %{text: "Hello."}] = Session.state(user).entries
    end
  end

  defp set_chat_idle_ms(ms) do
    previous = Application.get_env(:residency_schedule, :chat, [])
    Application.put_env(:residency_schedule, :chat, Keyword.put(previous, :session_idle_ms, ms))
    on_exit(fn -> Application.put_env(:residency_schedule, :chat, previous) end)
  end
end
