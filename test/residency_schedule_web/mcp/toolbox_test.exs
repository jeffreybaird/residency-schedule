defmodule ResidencyScheduleWeb.MCP.ToolboxTest do
  use ResidencySchedule.DataCase, async: true

  import ResidencySchedule.ScheduleFixtures

  alias ResidencySchedule.Assistant.Chat.{ToolCall, ToolResult}
  alias ResidencyScheduleWeb.MCP.{Toolbox, Tools}

  doctest Toolbox

  setup do
    fixtures = seed_mini_schedule()
    %{user: resident_user(fixtures.clare)}
  end

  describe "tools/0" do
    test "mirrors the MCP catalogue" do
      tools = Toolbox.tools()
      assert length(tools) == length(Tools.definitions())
      assert Enum.all?(tools, &(&1.input_schema.type == "object"))
    end
  end

  describe "mutating?/1" do
    test "unknown tools are mutating" do
      assert Toolbox.mutating?("delete_everything")
    end

    test "every write tool is mutating and every read tool is not" do
      for definition <- Tools.definitions() do
        assert Toolbox.mutating?(definition.name) == not definition.annotations.readOnlyHint
      end
    end
  end

  describe "run/2" do
    test "returns the tool's JSON text on success", %{user: user} do
      call =
        ToolCall.new("toolu_1", "who_is_on", %{"rotation" => "strong ob", "date" => "2026-07-15"})

      assert %ToolResult{call_id: "toolu_1", error?: false, content: content} =
               Toolbox.run(call, user)

      assert Jason.decode!(content)["rotation_type"] == "strong_obstetrics"
    end

    test "returns a business error as an error result", %{user: user} do
      call =
        ToolCall.new("toolu_1", "find_resident", %{"name" => "Nobody", "date" => "2026-07-15"})

      assert %ToolResult{error?: true, content: content} = Toolbox.run(call, user)
      assert content =~ "No resident named"
    end

    test "returns an error result for an unknown tool", %{user: user} do
      assert %ToolResult{error?: true, content: "Unknown tool: nope"} =
               Toolbox.run(ToolCall.new("toolu_1", "nope"), user)
    end
  end
end
