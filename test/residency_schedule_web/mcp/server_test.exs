defmodule ResidencyScheduleWeb.MCP.ServerTest do
  use ResidencySchedule.DataCase, async: true

  import ResidencySchedule.ScheduleFixtures

  alias ResidencySchedule.Accounts.User
  alias ResidencyScheduleWeb.MCP.Server

  doctest Server

  @user %User{id: 0, role: :resident, approved: true}

  defp request(method, params \\ %{}, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  describe "initialize" do
    test "negotiates the version and advertises tools" do
      assert {:reply, %{result: result}} =
               Server.handle(request("initialize", %{"protocolVersion" => "2025-03-26"}), @user)

      assert result.protocolVersion == "2025-03-26"
      assert result.capabilities.tools.listChanged == false
      assert result.serverInfo.name == "residency-schedule"
    end

    test "falls back to the latest version" do
      assert {:reply, %{result: %{protocolVersion: "2025-06-18"}}} =
               Server.handle(request("initialize"), @user)
    end
  end

  describe "tools/list" do
    test "returns definitions" do
      assert {:reply, %{result: %{tools: tools}}} = Server.handle(request("tools/list"), @user)
      assert Enum.any?(tools, &(&1.name == "check_coverage"))
    end
  end

  describe "tools/call" do
    test "runs a tool" do
      %{clare: clare} = seed_mini_schedule()
      user = resident_user(clare)

      assert {:reply, %{result: result}} =
               Server.handle(request("tools/call", %{"name" => "whoami"}), user)

      assert result.isError == false
      assert result.structuredContent.home_resident.name == "Clare"
    end

    test "unknown tool is a protocol error" do
      assert {:reply, %{error: %{code: -32_602, message: "Unknown tool: nope"}}} =
               Server.handle(request("tools/call", %{"name" => "nope"}), @user)
    end

    test "missing tool name is invalid params" do
      assert {:reply, %{error: %{code: -32_602}}} =
               Server.handle(request("tools/call", %{}), @user)
    end

    test "missing arguments default to none" do
      assert {:reply, %{result: %{isError: false}}} =
               Server.handle(request("tools/call", %{"name" => "whoami"}), @user)
    end
  end

  describe "other messages" do
    test "unknown method" do
      assert {:reply, %{error: %{code: -32_601}}} =
               Server.handle(request("resources/list"), @user)
    end

    test "responses are accepted" do
      assert :accepted = Server.handle(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}, @user)
    end

    test "garbage is invalid" do
      assert {:invalid, %{id: nil, error: %{code: -32_600}}} = Server.handle(%{"x" => 1}, @user)
    end
  end
end
