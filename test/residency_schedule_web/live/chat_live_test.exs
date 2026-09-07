defmodule ResidencyScheduleWeb.ChatLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.Assistant.Chat
  alias ResidencySchedule.Assistant.Chat.{Providers.Fake, Quota, ToolCall}
  alias ResidencySchedule.Assistant.LocalDate
  alias ResidencyScheduleWeb.ChatLive.Index

  doctest Index

  setup :authenticate_session

  defp send_message(view, text) do
    view |> form("#chat-form", %{"message" => text}) |> render_submit()
    render_async(view)
  end

  describe "unauthenticated access" do
    test "redirects to /login when no session" do
      assert redirected_to(get(build_conn(), "/chat")) == "/login"
    end
  end

  describe "when the assistant is off" do
    test "explains and offers no form", %{conn: conn} do
      set_demo_mode(true)
      {:ok, view, html} = live(conn, "/chat")
      assert html =~ "turned off"
      refute has_element?(view, "#chat-form")
    end
  end

  describe "a text conversation" do
    test "shows the user's message and the streamed reply", %{conn: conn} do
      Fake.script([{:text, "Nora is on onc."}])
      {:ok, view, html} = live(conn, "/chat")
      assert html =~ "50 messages left today"

      send_message(view, "Who is on onc?")
      assert has_element?(view, "[data-kind=user]", "Who is on onc?")
      assert has_element?(view, "[data-kind=assistant]", "Nora is on onc.")
      assert has_element?(view, "#chat-remaining", "49 messages left")
      refute has_element?(view, "#chat-thinking")
    end

    test "renders the reply's markdown and escapes HTML in it", %{conn: conn} do
      Fake.script([{:text, "**Today:**\n- Clare <b>x</b>\n- Mary"}])
      {:ok, view, _html} = live(conn, "/chat")

      send_message(view, "Who is on?")
      assert has_element?(view, "[data-kind=assistant] strong", "Today:")
      assert has_element?(view, "[data-kind=assistant] ul li", "Mary")
      assert has_element?(view, "[data-kind=assistant] li", "Clare <b>x</b>")
      refute has_element?(view, "[data-kind=assistant] b")
    end

    test "ignores blank messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")
      send_message(view, "   ")
      refute has_element?(view, "[data-kind=user]")
      assert has_element?(view, "#chat-remaining", "50 messages left")
    end

    test "shows provider errors and keeps the conversation usable", %{conn: conn} do
      Fake.script([
        {:error, {:api_error, %{status: 529, type: "overloaded_error", message: "Overloaded"}}},
        {:text, "Back."}
      ])

      {:ok, view, _html} = live(conn, "/chat")

      send_message(view, "Hi")
      assert has_element?(view, "#chat-error", "Overloaded")

      send_message(view, "Again")
      refute has_element?(view, "#chat-error")
      assert has_element?(view, "[data-kind=assistant]", "Back.")
    end

    test "new chat clears the log", %{conn: conn} do
      Fake.script([{:text, "Hello."}])
      {:ok, view, _html} = live(conn, "/chat")
      send_message(view, "Hi")
      view |> element("button", "New chat") |> render_click()
      refute has_element?(view, "[data-kind=user]")
    end

    test "stops at the daily limit", %{conn: conn, user: user} do
      today = LocalDate.today()
      limit = Chat.daily_limit()
      for _ <- 1..limit, do: {:ok, _} = Quota.consume(user, today)

      {:ok, view, html} = live(conn, "/chat")
      assert html =~ "0 messages left today"
      send_message(view, "Hi")
      assert has_element?(view, "#chat-error", "used today's #{limit} messages")
      refute has_element?(view, "[data-kind=user]")
    end
  end

  describe "tool calls" do
    setup do
      seed_schedule(2026)
      :ok
    end

    test "read-only tools run and are shown", %{conn: conn} do
      call =
        ToolCall.new("toolu_1", "who_is_on", %{"rotation" => "strong ob", "date" => "2026-07-15"})

      Fake.script([{:tool_calls, "Checking.", [call]}, {:text, "Found them."}])
      {:ok, view, _html} = live(conn, "/chat")

      send_message(view, "Who is on strong ob?")
      assert has_element?(view, "[data-kind=tool][data-status=ok]", "Used Who is on")
      assert has_element?(view, "[data-kind=assistant]", "Found them.")
      refute has_element?(view, "#chat-approval")
    end

    test "a failing tool is shown with its message", %{conn: conn} do
      call = ToolCall.new("toolu_1", "find_resident", %{"name" => "Nobody"})
      Fake.script([{:tool_calls, nil, [call]}, {:text, "No such resident."}])
      {:ok, view, _html} = live(conn, "/chat")

      send_message(view, "Find Nobody")
      assert has_element?(view, "[data-kind=tool][data-status=error]", "No resident named")
    end

    test "a mutating tool waits for approval and then runs", %{conn: conn} do
      call =
        ToolCall.new("toolu_1", "request_coverage", %{
          "covering" => "Nora",
          "start_date" => "2026-07-15"
        })

      Fake.script([{:tool_calls, "I will file it.", [call]}, {:text, "Filed."}])
      {:ok, view, _html} = live(conn, "/chat")

      send_message(view, "Cover me")
      assert has_element?(view, "#chat-approval", "Request coverage")
      assert has_element?(view, "#chat-approval pre", "covering: Nora")
      assert has_element?(view, "#chat-form input[disabled]")

      view |> element("#chat-approval button", "Approve") |> render_click()
      render_async(view)
      refute has_element?(view, "#chat-approval")
      assert has_element?(view, "[data-kind=tool][data-status=error]", "Request coverage failed")
      assert has_element?(view, "[data-kind=assistant]", "Filed.")
    end

    test "denying tells the model and lets it answer", %{conn: conn} do
      call = ToolCall.new("toolu_1", "cancel_change_request", %{"request_id" => 1})

      Fake.script([
        {:tool_calls, nil, [call]},
        fn request -> {:text, "Declined: " <> last_tool_result(request)} end
      ])

      {:ok, view, _html} = live(conn, "/chat")

      send_message(view, "Cancel my request")
      view |> element("#chat-approval button", "Deny") |> render_click()
      render_async(view)

      assert has_element?(
               view,
               "[data-kind=assistant]",
               "Declined: The user declined this action"
             )

      assert has_element?(view, "[data-kind=tool][data-status=error]", "declined")
    end
  end

  defp last_tool_result(request) do
    request.messages |> List.last() |> Map.fetch!(:parts) |> hd() |> Map.fetch!(:content)
  end
end
