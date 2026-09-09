defmodule ResidencyScheduleWeb.ChatWidgetTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.Assistant.Chat
  alias ResidencySchedule.Assistant.Chat.{Providers.Fake, Quota, ToolCall}
  alias ResidencySchedule.Assistant.LocalDate
  alias ResidencyScheduleWeb.ChatLive.Widget

  doctest Widget

  setup :authenticate_session

  # Mounts the widget on its own and opens the panel, as a user would by
  # clicking the launcher.
  defp open_widget(conn) do
    {:ok, view, _html} = live_isolated(conn, Widget)
    view |> element("#chat-launcher") |> render_click()
    view
  end

  defp send_message(view, text) do
    view |> form("#chat-form", %{"message" => text}) |> render_submit()
    render_async(view)
  end

  describe "placement in the layout" do
    test "signed-in pages carry the widget as a sticky child", %{conn: conn} do
      html = conn |> get("/") |> html_response(200)
      assert html =~ ~s(id="chat-widget")
      assert html =~ ~s(data-phx-sticky)
      assert html =~ ~s(id="chat-launcher")
      refute html =~ ~s(id="chat-panel")
    end

    test "admin pages carry the widget too" do
      %{conn: conn} = admin_authenticate_session(%{conn: build_conn()})
      html = conn |> get("/admin") |> html_response(200)
      assert html =~ ~s(id="chat-widget")
      assert html =~ ~s(data-phx-sticky)
    end

    # The widget surviving live navigation is a client behaviour: the browser
    # carries the sticky element into the next page instead of re-joining it.
    # Phoenix.LiveViewTest re-joins it and fails, so that half is checked in
    # a browser, not here. See DataCase.set_chat_enabled/1.

    test "the login page has no widget" do
      html = build_conn() |> get("/login") |> html_response(200)
      refute html =~ ~s(id="chat-widget")
    end

    test "demo mode has no widget and no nav link", %{conn: conn} do
      set_demo_mode(true)
      html = conn |> get("/") |> html_response(200)
      refute html =~ ~s(id="chat-widget")
      refute html =~ "/chat"
    end

    test "the old chat page is gone", %{conn: conn} do
      assert get(conn, "/chat").status == 404
    end
  end

  describe "mounting on its own" do
    test "redirects to /login without a session" do
      conn = Plug.Test.init_test_session(build_conn(), %{})
      assert {:error, {:redirect, %{to: "/login"}}} = live_isolated(conn, Widget)
    end

    test "renders nothing when the assistant is off", %{conn: conn} do
      set_demo_mode(true)
      {:ok, view, _html} = live_isolated(conn, Widget)
      refute has_element?(view, "#chat-launcher")
      refute has_element?(view, "#chat-panel")
    end
  end

  describe "opening and closing" do
    test "starts as a launcher and opens into the panel", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, Widget)
      assert has_element?(view, "#chat-launcher[aria-label='Open the assistant']")
      refute has_element?(view, "#chat-panel")

      view |> element("#chat-launcher") |> render_click()
      assert has_element?(view, "#chat-panel[role=dialog]")
      assert has_element?(view, "#chat-form input[phx-mounted]")
      assert has_element?(view, "#chat-remaining", "50 messages left today")
      refute has_element?(view, "#chat-launcher")
    end

    test "the x closes the panel and keeps the conversation", %{conn: conn} do
      Fake.script([{:text, "Nora is on onc."}])
      view = open_widget(conn)
      send_message(view, "Who is on onc?")

      view |> element("#chat-close[aria-label='Close the assistant']") |> render_click()
      refute has_element?(view, "#chat-panel")
      assert has_element?(view, "#chat-launcher")

      view |> element("#chat-launcher") |> render_click()
      assert has_element?(view, "[data-kind=assistant]", "Nora is on onc.")
    end
  end

  describe "a text conversation" do
    test "shows the user's message and the streamed reply", %{conn: conn} do
      Fake.script([{:text, "Nora is on onc."}])
      view = open_widget(conn)

      send_message(view, "Who is on onc?")
      assert has_element?(view, "[data-kind=user]", "Who is on onc?")
      assert has_element?(view, "[data-kind=assistant]", "Nora is on onc.")
      assert has_element?(view, "#chat-remaining", "49 messages left")
      refute has_element?(view, "#chat-thinking")
    end

    test "renders the reply's markdown and escapes HTML in it", %{conn: conn} do
      Fake.script([{:text, "**Today:**\n- Clare <b>x</b>\n- Mary"}])
      view = open_widget(conn)

      send_message(view, "Who is on?")
      assert has_element?(view, "[data-kind=assistant] strong", "Today:")
      assert has_element?(view, "[data-kind=assistant] ul li", "Mary")
      assert has_element?(view, "[data-kind=assistant] li", "Clare <b>x</b>")
      refute has_element?(view, "[data-kind=assistant] b")
    end

    test "renders bubbles with tight, industry-standard padding", %{conn: conn} do
      Fake.script([{:text, "Nora is on onc."}])
      view = open_widget(conn)

      html = send_message(view, "Who is on onc?")
      assert html =~ ~s(bg-blue-600 px-3 py-2)
      assert html =~ ~s(bg-gray-100 px-3 py-2)
    end

    # A whitespace-pre-wrap bubble renders any template indentation around the
    # interpolation as visible blank lines and leading spaces, which reads as
    # oversized padding. The text must sit flush against the bubble edges.
    test "the user bubble has no whitespace padding its text", %{conn: conn} do
      Fake.script([{:text, "Sure."}])
      view = open_widget(conn)

      html = send_message(view, "Who is on onc?")
      assert html =~ ~s(whitespace-pre-wrap">Who is on onc?</p>)
    end

    test "ignores blank messages", %{conn: conn} do
      view = open_widget(conn)
      send_message(view, "   ")
      refute has_element?(view, "[data-kind=user]")
      assert has_element?(view, "#chat-remaining", "50 messages left")
    end

    test "shows provider errors and keeps the conversation usable", %{conn: conn} do
      Fake.script([
        {:error, {:api_error, %{status: 529, type: "overloaded_error", message: "Overloaded"}}},
        {:text, "Back."}
      ])

      view = open_widget(conn)

      send_message(view, "Hi")
      assert has_element?(view, "#chat-error", "Overloaded")

      send_message(view, "Again")
      refute has_element?(view, "#chat-error")
      assert has_element?(view, "[data-kind=assistant]", "Back.")
    end

    test "a crash inside the turn is reported and logged", %{conn: conn} do
      Fake.script([fn _request -> raise "boom" end, {:text, "Recovered."}])
      view = open_widget(conn)

      log = ExUnit.CaptureLog.capture_log(fn -> send_message(view, "Hi") end)
      assert log =~ "chat turn crashed"
      assert log =~ "boom"
      assert has_element?(view, "#chat-error", "stopped unexpectedly")

      send_message(view, "Again")
      assert has_element?(view, "[data-kind=assistant]", "Recovered.")
    end

    test "new chat clears the log", %{conn: conn} do
      Fake.script([{:text, "Hello."}])
      view = open_widget(conn)
      send_message(view, "Hi")
      view |> element("button", "New chat") |> render_click()
      refute has_element?(view, "[data-kind=user]")
    end

    test "stops at the daily limit", %{conn: conn, user: user} do
      today = LocalDate.today()
      limit = Chat.daily_limit()
      for _ <- 1..limit, do: {:ok, _} = Quota.consume(user, today)

      view = open_widget(conn)
      assert has_element?(view, "#chat-remaining", "0 messages left today")
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
      view = open_widget(conn)

      send_message(view, "Who is on strong ob?")
      assert has_element?(view, "[data-kind=tool][data-status=ok]", "Used Who is on")
      assert has_element?(view, "[data-kind=assistant]", "Found them.")
      refute has_element?(view, "#chat-approval")
    end

    test "a failing tool is shown with its message", %{conn: conn} do
      call = ToolCall.new("toolu_1", "find_resident", %{"name" => "Nobody"})
      Fake.script([{:tool_calls, nil, [call]}, {:text, "No such resident."}])
      view = open_widget(conn)

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
      view = open_widget(conn)

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

      view = open_widget(conn)

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
