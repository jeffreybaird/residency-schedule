defmodule ResidencyScheduleWeb.UploadLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "unauthenticated access" do
    test "redirects to /login when not logged in", %{conn: conn} do
      conn = get(conn, "/admin/upload")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "upload page" do
    setup %{conn: conn} do
      %{conn: conn} = admin_authenticate_session(%{conn: conn})
      {:ok, view, html} = live(conn, "/admin/upload")
      %{view: view, html: html}
    end

    test "renders Upload Schedule heading", %{html: html} do
      assert html =~ "Upload Schedule"
    end

    test "renders Import Schedule submit button", %{html: html} do
      assert html =~ "Import Schedule"
    end

    test "renders Back to Admin link", %{html: html} do
      assert html =~ "Back to Admin"
    end

    test "shows error when save submitted with no file", %{view: view} do
      html = view |> element("form[phx-submit='save']") |> render_submit()
      assert html =~ "Please select a CSV file"
    end
  end
end
