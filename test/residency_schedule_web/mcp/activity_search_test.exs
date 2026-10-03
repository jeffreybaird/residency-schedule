defmodule ResidencyScheduleWeb.MCP.ActivitySearchTest do
  use ResidencySchedule.DataCase

  import ResidencySchedule.ActivitySearchFixtures

  alias ResidencySchedule.{Accounts, Assistant, DetailedSchedules}
  alias ResidencySchedule.Assistant.Chat.{Prompt, ToolCall, ToolResult}
  alias ResidencyScheduleWeb.MCP.{Server, Toolbox, Tools}

  setup do
    data = seed_activity_search()

    {:ok, caller} =
      Accounts.create_user(%{
        email: "activity-reader-#{System.unique_integer([:positive])}@urmc.rochester.edu"
      })

    {:ok, caller} = Accounts.set_home_resident(caller, data.iris.resident_id)
    Map.put(data, :caller, caller)
  end

  test "catalogue exposes bounded read-only activity search and chat mirrors it" do
    definition = Enum.find(Tools.definitions(), &(&1.name == "search_activities"))
    assert definition
    assert definition.annotations.readOnlyHint
    assert definition.annotations.idempotentHint
    refute definition.annotations.destructiveHint
    assert definition.inputSchema.required == ["academic_year"]
    properties = definition.inputSchema.properties

    assert Enum.sort(Map.keys(properties)) ==
             Enum.sort([
               :academic_year,
               :query,
               :start_date,
               :end_date,
               :resident_id,
               :page,
               :page_size
             ])

    assert properties.academic_year.type == "integer"
    assert properties.academic_year.minimum == 1
    assert properties.academic_year.maximum == 9998
    assert properties.query.maxLength == 200
    assert properties.page.minimum == 1
    assert properties.page.maximum == 10_000
    assert properties.page_size.minimum == 1
    assert properties.page_size.maximum == 100
    assert properties.resident_id.minimum == 1
    chat_tool = Enum.find(Toolbox.tools(), &(&1.name == "search_activities"))
    assert chat_tool.input_schema == definition.inputSchema
    refute Toolbox.mutating?("search_activities")
  end

  test "returns the shared neutral page with full names and literal note matches", ctx do
    for query <- ["SIMULATION", "%", "_", "\\"] do
      args = %{"academic_year" => 2026, "query" => query}
      assert {:ok, expected} = DetailedSchedules.search(args)

      assert {:ok, %{isError: false, structuredContent: page, content: [text]}} =
               Tools.call("search_activities", args, ctx.caller)

      assert page == expected
      assert page.total == 1
      assert Jason.decode!(text.text) == Jason.decode!(Jason.encode!(page))
      [entry] = page.entries
      assert entry.display_name == "Iris Reed"

      assert Enum.sort(Map.keys(entry)) ==
               Enum.sort([
                 :id,
                 :schedule_resident_id,
                 :resident_id,
                 :position_code,
                 :date,
                 :raw_task,
                 :period,
                 :site,
                 :display_name,
                 :notes
               ])
    end
  end

  test "full name and legacy alias match the same person without merging similar names", ctx do
    for query <- ["Juniper Vale", "Juniper Vail"] do
      assert {:ok, %{isError: false, structuredContent: page}} =
               Tools.call(
                 "search_activities",
                 %{"academic_year" => 2026, "query" => query},
                 ctx.caller
               )

      assert page.total == 2
      assert Enum.all?(page.entries, &(&1.resident_id == ctx.juniper.resident_id))
      assert Enum.all?(page.entries, &(&1.display_name == "Juniper Vale"))
    end

    args = %{
      "academic_year" => 2026,
      "resident_id" => ctx.iris.resident_id,
      "start_date" => "2026-12-29",
      "end_date" => "2026-12-29"
    }

    assert {:ok, %{isError: false, structuredContent: page}} =
             Tools.call("search_activities", args, ctx.caller)

    assert page.total == 2

    assert Enum.all?(
             page.entries,
             &(&1.resident_id == ctx.iris.resident_id and &1.date == ~D[2026-12-29])
           )
  end

  test "pagination remains deterministic and bounded", ctx do
    pages =
      for number <- 1..3 do
        assert {:ok, %{isError: false, structuredContent: page}} =
                 Tools.call(
                   "search_activities",
                   %{"academic_year" => 2026, "page" => number, "page_size" => 3},
                   ctx.caller
                 )

        assert page.total == 8
        assert page.page == number
        assert page.page_size == 3
        page.entries
      end

    assert Enum.map(pages, &length/1) == [3, 3, 2]
    assert pages |> List.flatten() |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 8
  end

  test "malformed filters produce business errors without a broadened result", ctx do
    for args <- [
          %{},
          %{"academic_year" => 9999},
          %{"academic_year" => 2026, "query" => %{}},
          %{"academic_year" => 2026, "resident_id" => %{}},
          %{"academic_year" => 2026, "page" => 10_001},
          %{"academic_year" => 2026, "page_size" => 101},
          %{"academic_year" => 2026, "query" => String.duplicate("x", 201)},
          %{"academic_year" => 2026, "start_date" => "invalid"},
          %{"academic_year" => 2026, "start_date" => "2027-01-03", "end_date" => "2026-12-28"}
        ] do
      assert {:ok, result} = Tools.call("search_activities", args, ctx.caller)
      assert result.isError
      refute Map.has_key?(result, :structuredContent)
      assert [%{type: "text", text: message}] = result.content
      assert is_binary(message) and byte_size(message) > 0
    end
  end

  test "MCP protocol and in-app chat dispatch the same search", ctx do
    args = %{"academic_year" => 2026, "query" => "simulation"}

    request = %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{"name" => "search_activities", "arguments" => args}
    }

    assert {:reply, %{result: %{isError: false, structuredContent: page}}} =
             Server.handle(request, ctx.caller)

    call = ToolCall.new("activity-call", "search_activities", args)

    assert %ToolResult{call_id: "activity-call", error?: false, content: content} =
             Toolbox.run(call, ctx.caller)

    assert Jason.decode!(content) == Jason.decode!(Jason.encode!(page))
  end

  test "empty results report records only and never inferred availability", ctx do
    assert {:ok, %{isError: false, structuredContent: page}} =
             Tools.call(
               "search_activities",
               %{"academic_year" => 2026, "query" => "no such task"},
               ctx.caller
             )

    assert page == %{entries: [], total: 0, page: 1, page_size: 50}
  end

  test "rotation tools retain their existing context result shapes after activities are saved",
       ctx do
    assert {:ok, expected_service} = Assistant.who_is_on("strong gyn", "2026-12-29")

    assert {:ok, %{isError: false, structuredContent: service}} =
             Tools.call(
               "who_is_on",
               %{"rotation" => "strong gyn", "date" => "2026-12-29"},
               ctx.caller
             )

    assert service == expected_service

    assert {:ok, expected_schedule} =
             Assistant.resident_schedule("Iris Reed", "2026-12-28", "2027-01-03")

    assert {:ok, %{isError: false, structuredContent: schedule}} =
             Tools.call(
               "resident_schedule",
               %{"name" => "Iris Reed", "from" => "2026-12-28", "to" => "2027-01-03"},
               ctx.caller
             )

    assert schedule == expected_schedule
  end

  test "tool and chat guidance directs daily commitments to activity search without availability inference" do
    definition = Enum.find(Tools.definitions(), &(&1.name == "search_activities"))
    assert definition

    for name <- ["who_is_on", "resident_schedule"] do
      rotation_tool = Enum.find(Tools.definitions(), &(&1.name == name))
      assert rotation_tool.description =~ "search_activities"
    end

    guidance = String.downcase(definition.description)
    assert guidance =~ "clinic"
    assert guidance =~ "availability"
    prompt = Prompt.system(~D[2026-12-29]) |> String.downcase()
    assert prompt =~ "search_activities"
    assert prompt =~ "clinic"
    assert prompt =~ "availability"
  end
end
