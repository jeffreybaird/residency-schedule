defmodule ResidencyScheduleWeb.LiveNavigationTest do
  @moduledoc """
  Every signed-in page shares one live session, so the nav in the root layout
  moves between them without a page load. These tests pin the two halves of
  that: the links ask for live navigation, and the admin pages still enforce
  the admin role on a mount the router plugs never see.
  """
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.{Accounts, Residents}

  @admin_paths ["/admin", "/admin/denied", "/admin/upload", "/admin/build", "/admin/edit"]

  defp live_link(html, path) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(a[href="#{path}"][data-phx-link="redirect"]))
    |> LazyHTML.attribute("href")
  end

  defp home_link(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#tour-nav a[data-nav-home]")
  end

  describe "the nav links" do
    setup :authenticate_session

    test "navigate live to the site pages", %{conn: conn} do
      html = conn |> get("/") |> html_response(200)

      for path <- ["/", "/schedule", "/compare"] do
        assert live_link(html, path) != [], "expected a live link to #{path}"
      end

      assert html =~ ~s(id="mobile-nav")
    end

    test "navigate live to the admin pages for an admin" do
      %{conn: conn} = admin_authenticate_session(%{conn: build_conn()})
      html = conn |> get("/") |> html_response(200)

      for path <- ["/admin", "/admin/build", "/admin/edit"] do
        assert live_link(html, path) != [], "expected a live link to #{path}"
      end
    end

    test "mark the home link current only on its own page", %{conn: conn, user: user} do
      seed_schedule()
      resident = Residents.get_resident_by_position!("R4-1")
      {:ok, _} = Accounts.set_home_resident(user, resident.resident_id)
      path = "/residents/#{resident.id}"

      on_home = conn |> get(path) |> html_response(200) |> home_link()
      assert LazyHTML.attribute(on_home, "href") == [path]
      assert LazyHTML.attribute(on_home, "aria-current") == ["page"]

      elsewhere = conn |> get("/") |> html_response(200) |> home_link()
      assert LazyHTML.attribute(elsewhere, "href") == [path]
      assert LazyHTML.attribute(elsewhere, "aria-current") == []
    end
  end

  # Live navigation in these tests runs with the assistant off; see
  # DataCase.set_chat_enabled/1 for why the test client cannot carry it along.
  describe "live navigation for an admin" do
    setup :admin_authenticate_session
    setup do: set_chat_enabled(false)

    test "reaches every admin page and comes back", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view =
        Enum.reduce(@admin_paths, view, fn path, view ->
          assert {:ok, view, _html} = live_redirect(view, to: path),
                 "could not navigate to #{path}"

          view
        end)

      assert {:ok, _view, html} = live_redirect(view, to: "/schedule")
      assert html =~ "Schedule"
    end
  end

  describe "live navigation for a non-admin" do
    setup :authenticate_session
    setup do: set_chat_enabled(false)

    test "is turned back from every admin page", %{conn: conn} do
      for path <- @admin_paths do
        {:ok, view, _html} = live(conn, "/")

        assert {:error, {:redirect, %{to: "/"}}} = live_redirect(view, to: path),
               "expected #{path} to redirect a non-admin"
      end
    end
  end
end
