defmodule ResidencyScheduleWeb.MCP.ToolsTest do
  use ResidencySchedule.DataCase, async: true

  import ResidencySchedule.ScheduleFixtures

  alias ResidencySchedule.ChangeRequests
  alias ResidencyScheduleWeb.MCP.Tools

  doctest Tools

  setup do
    fixtures = seed_mini_schedule()

    Map.merge(fixtures, %{
      clare_user: resident_user(fixtures.clare),
      admin: admin_user(),
      mary_user: resident_user(fixtures.mary)
    })
  end

  defp call(name, args, user) do
    {:ok, result} = Tools.call(name, args, user)
    result
  end

  describe "definitions/0" do
    test "every tool has a schema, description, and annotations" do
      for tool <- Tools.definitions() do
        assert tool.inputSchema.type == "object"
        assert is_binary(tool.description)
        assert is_boolean(tool.annotations.readOnlyHint)
      end
    end
  end

  describe "read tools" do
    test "who_is_on returns structured content and a text block", ctx do
      result =
        call("who_is_on", %{"rotation" => "strong ob", "date" => "2026-07-15"}, ctx.clare_user)

      refute result.isError
      assert [%{type: "text", text: text}] = result.content
      assert Jason.decode!(text)["rotation_type"] == "strong_obstetrics"
      assert Enum.map(result.structuredContent.assignments, & &1.name) == ["Mary", "Tiff"]
    end

    test "find_resident, resident_schedule, and shared_shifts", ctx do
      assert %{structuredContent: %{name: "Tiff"}} =
               call("find_resident", %{"name" => "tiff", "date" => "2026-07-10"}, ctx.clare_user)

      assert %{structuredContent: %{segments: [_ | _]}} =
               call(
                 "resident_schedule",
                 %{"name" => "clare", "from" => "2026-07-06", "to" => "2026-07-31"},
                 ctx.clare_user
               )

      assert %{structuredContent: %{count: 7}} =
               call(
                 "shared_shifts",
                 %{"resident" => "clare", "coworker" => "mary", "from" => "2026-07-06"},
                 ctx.clare_user
               )
    end

    test "business errors come back as isError results", ctx do
      result = call("who_is_on", %{"rotation" => "dermatology"}, ctx.clare_user)
      assert result.isError
      assert [%{text: text}] = result.content
      assert text =~ "Unknown rotation"

      assert %{isError: true, content: [%{text: text}]} =
               call("find_resident", %{"name" => "Zed", "date" => "2026-07-10"}, ctx.clare_user)

      assert text =~ "No resident named"

      assert %{isError: true, content: [%{text: text}]} =
               call("find_resident", %{"name" => "tiff", "date" => "soon"}, ctx.clare_user)

      assert text =~ "ISO 8601"
    end

    test "non-map arguments are treated as empty", ctx do
      assert {:ok, %{isError: false}} = Tools.call("whoami", nil, ctx.clare_user)
    end

    test "unknown tool", ctx do
      assert {:error, :unknown_tool} = Tools.call("nope", %{}, ctx.clare_user)
    end
  end

  describe "coverage workflow" do
    test "check, request, list, review, cancel", ctx do
      check =
        call(
          "check_coverage",
          %{"covering" => "clare", "original" => "tiff", "start_date" => "2026-07-15"},
          ctx.clare_user
        )

      assert check.structuredContent.can_file
      refute check.structuredContent.duty_hours.violates

      filed =
        call(
          "request_coverage",
          %{
            "covering" => "clare",
            "original" => "tiff",
            "start_date" => "2026-07-15",
            "end_date" => "2026-07-16",
            "note" => "swap"
          },
          ctx.clare_user
        )

      refute filed.isError
      assert filed.structuredContent.status == :pending
      id = filed.structuredContent.id

      assert %{structuredContent: %{count: 1}} =
               call("list_change_requests", %{"status" => "pending"}, ctx.admin)

      assert %{structuredContent: %{count: 0}} = call("list_change_requests", %{}, ctx.mary_user)

      assert %{isError: true, content: [%{text: text}]} =
               call("list_change_requests", %{"status" => "weird"}, ctx.admin)

      assert text =~ "status must be"

      assert %{isError: true, content: [%{text: text}]} =
               call(
                 "review_change_request",
                 %{"request_id" => id, "decision" => "approve"},
                 ctx.clare_user
               )

      assert text =~ "permission"

      assert %{isError: true} =
               call(
                 "review_change_request",
                 %{"request_id" => id, "decision" => "maybe"},
                 ctx.admin
               )

      assert %{isError: true} =
               call(
                 "review_change_request",
                 %{"request_id" => "x", "decision" => "approve"},
                 ctx.admin
               )

      assert %{isError: true} =
               call(
                 "review_change_request",
                 %{"request_id" => 1.5, "decision" => "approve"},
                 ctx.admin
               )

      approved =
        call(
          "review_change_request",
          %{"request_id" => Integer.to_string(id), "decision" => "approve", "note" => "fine"},
          ctx.admin
        )

      refute approved.isError
      assert approved.structuredContent.status == :approved
      assert approved.structuredContent.reviewed_by == ctx.admin.email

      assert %{isError: true, content: [%{text: text}]} =
               call("cancel_change_request", %{"request_id" => id}, ctx.clare_user)

      assert text =~ "already been decided"
    end

    test "deny and cancel paths", ctx do
      filed =
        call(
          "request_coverage",
          %{"covering" => "clare", "original" => "tiff", "start_date" => "2026-07-15"},
          ctx.clare_user
        )

      id = filed.structuredContent.id

      assert %{structuredContent: %{status: :cancelled}} =
               call("cancel_change_request", %{"request_id" => id}, ctx.clare_user)

      filed =
        call(
          "request_coverage",
          %{"covering" => "clare", "original" => "tiff", "start_date" => "2026-07-15"},
          ctx.tiff |> resident_user()
        )

      id = filed.structuredContent.id

      assert %{structuredContent: %{status: :denied, review_note: "no"}} =
               call(
                 "review_change_request",
                 %{"request_id" => id, "decision" => "deny", "note" => "no"},
                 ctx.admin
               )

      assert [] = ChangeRequests.list_requests(ctx.admin, :pending)
    end

    test "uninvolved user cannot file", ctx do
      assert %{isError: true, content: [%{text: text}]} =
               call(
                 "request_coverage",
                 %{"covering" => "clare", "original" => "tiff", "start_date" => "2026-07-15"},
                 ctx.mary_user
               )

      assert text =~ "permission"
    end
  end

  describe "describe_error/1" do
    test "covers remaining reasons" do
      for reason <- [
            :no_schedule,
            :rotation_not_found,
            :covering_resident_not_found,
            :covering_is_original,
            :different_schedules,
            :dates_outside_rotation,
            :already_covered,
            :covering_resident_busy,
            :duplicate_request,
            :not_found,
            :not_pending,
            :invalid_decision,
            :invalid_status,
            :invalid_request_id
          ] do
        assert is_binary(Tools.describe_error(reason))
      end

      assert Tools.describe_error({:resident_not_found, "Zed"}) =~ "Zed"
      assert Tools.describe_error({:no_rotation_on_date, "Tiff", ~D[2026-09-01]}) =~ "2026-09-01"

      assert Tools.describe_error(%Ecto.Changeset{errors: [note: {"bad", []}]}) =~
               "Invalid request"

      assert Tools.describe_error(:something_else) =~ "something_else"
    end
  end
end
