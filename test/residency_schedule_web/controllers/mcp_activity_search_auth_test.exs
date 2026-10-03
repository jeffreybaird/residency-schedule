defmodule ResidencyScheduleWeb.MCPActivitySearchAuthTest do
  use ResidencyScheduleWeb.ConnCase, async: true

  test "activity search requires the existing MCP bearer authentication", %{conn: conn} do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "search_activities", "arguments" => %{"academic_year" => 2026}}
    }

    response = post(conn, "/mcp", body)
    assert response.status == 401
    assert [challenge] = get_resp_header(response, "www-authenticate")
    assert challenge =~ "resource_metadata="
  end
end
