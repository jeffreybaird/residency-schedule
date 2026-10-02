defmodule ResidencyScheduleWeb.ThemeControlsTest do
  use ResidencyScheduleWeb.ConnCase

  test "root navigation exposes accessible native theme buttons outside the desktop menu", %{
    conn: conn
  } do
    document = conn |> get("/login") |> html_response(200) |> LazyHTML.from_document()

    for theme <- ["system", "light", "dark"] do
      selector = "nav button[data-phx-theme='#{theme}'][aria-label='Use #{theme} theme']"
      assert document |> LazyHTML.query(selector) |> Enum.count() == 1

      assert document
             |> LazyHTML.query("#{selector}[aria-pressed]")
             |> Enum.count() == 1

      assert document
             |> LazyHTML.query("#tour-nav button[data-phx-theme='#{theme}']")
             |> Enum.empty?()
    end
  end
end
