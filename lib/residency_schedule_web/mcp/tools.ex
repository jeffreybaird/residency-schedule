defmodule ResidencyScheduleWeb.MCP.Tools do
  @moduledoc """
  The MCP tool catalogue and dispatcher. Each tool maps onto one
  `ResidencySchedule.Assistant` or `ResidencySchedule.ChangeRequests` call.
  Results are returned as `structuredContent` plus a JSON text block, per the
  MCP tools spec; business errors come back as `isError: true` results with a
  human-readable message so the model can recover.
  """

  alias ResidencySchedule.Accounts.User
  alias ResidencySchedule.{Assistant, ChangeRequests}

  @date_desc "ISO 8601 date (YYYY-MM-DD). Defaults to today in America/New_York."

  @doc """
  Tool definitions for `tools/list`.

      iex> names = ResidencyScheduleWeb.MCP.Tools.definitions() |> Enum.map(& &1.name)
      iex> "who_is_on" in names and "request_coverage" in names
      true
  """
  def definitions do
    [
      tool(
        "whoami",
        "Who am I?",
        "Returns the calling user's email, role, home resident, today's date, and the server build with the names of every tool it serves. Call this first when a question refers to 'me' or 'my', or to check whether your tool list is up to date.",
        %{},
        [],
        read_only: true
      ),
      tool(
        "find_resident",
        "Find a resident",
        "Resolves a first name or nickname to one resident in the schedule active on the date. Reports candidates when the name is ambiguous.",
        %{name: string("Resident's name, e.g. 'Clare' or 'Nora K'."), date: string(@date_desc)},
        ["name"],
        read_only: true
      ),
      tool(
        "list_residents",
        "List residents",
        "Lists the residents in a schedule with their position codes and residency years. " <>
          "Filter with residency_year (1–4, e.g. 2 for the R2 class). academic_year picks the schedule by its start year (e.g. 2026 for 2026–2027); defaults to the schedule active today.",
        %{
          residency_year: %{
            type: "integer",
            description: "Residency year 1–4. Omit for everyone."
          },
          academic_year: %{
            type: "integer",
            description: "Schedule start year, e.g. 2026. Defaults to the current schedule."
          }
        },
        [],
        read_only: true
      ),
      tool(
        "who_is_on",
        "Who is on a service",
        "Lists residents effectively working a rotation on a date, with approved coverage applied. Accepts shorthand like 'strong ob', 'onc', 'NF', 'highland gyn'. On weekends the weekend day/night counterparts are included.",
        %{rotation: string("Rotation name or shorthand."), date: string(@date_desc)},
        ["rotation"],
        read_only: true
      ),
      tool(
        "resident_schedule",
        "A resident's schedule",
        "A resident's effective rotation blocks (approved coverage applied) between two dates.",
        %{
          name: string("Resident's name."),
          from: string("Start of range. " <> @date_desc),
          to: string("End of range (inclusive). Defaults to the end of the schedule.")
        },
        ["name"],
        read_only: true
      ),
      tool(
        "shifts_remaining",
        "A resident's remaining shifts",
        "Counts one resident's working days (shifts) from a date onward, by rotation, with approved coverage applied. " <>
          "Every rotation is a shift except vacation and post-call; float, swing, away, ambulatory, and elective all count. " <>
          "Use it for 'how many shifts does X have left'. For shifts shared with a specific coworker use shared_shifts.",
        %{
          name: string("Resident's name."),
          from: string("Count from this date. " <> @date_desc),
          to: string("Count through this date (inclusive). Defaults to the end of the schedule.")
        },
        ["name"],
        read_only: true
      ),
      tool(
        "shared_shifts",
        "Shared shifts between two residents",
        "Counts the days two residents are on the same shared service at the same time (approved coverage applied) from a date onward. " <>
          "Use it for 'how many shifts does X have left with Y'. Only rotations that can hold more than one resident count: OB, gyn, onc, night float, weekend blocks, REI, urogyn, ultrasound. " <>
          "Float, swing, away, ambulatory, and elective are working days but solo, so they are never shared; vacation and post-call are not shifts. " <>
          "The result's counting_rule spells this out. For a resident's own shift count use shifts_remaining.",
        %{
          resident: string("First resident's name."),
          coworker: string("Second resident's name."),
          from: string("Count from this date. " <> @date_desc),
          to: string("Count through this date (inclusive). Defaults to the end of the schedule.")
        },
        ["resident", "coworker"],
        read_only: true
      ),
      tool(
        "shared_shifts_by_coworker",
        "Shared shifts with every coworker",
        "For one resident, counts the shared shifts with each other resident in the schedule from a date onward, most shared first, zeros included. " <>
          "Same counting rule as shared_shifts: only days on the same shared service count; solo rotations (float, swing, away, ambulatory, elective) never do. " <>
          "Use it for 'who does X work with most' or 'who does X never work with'.",
        %{
          name: string("Resident's name."),
          from: string("Count from this date. " <> @date_desc),
          to: string("Count through this date (inclusive). Defaults to the end of the schedule.")
        },
        ["name"],
        read_only: true
      ),
      tool(
        "shared_shift_matrix",
        "Shared shifts for every pair of residents",
        "Shared-shift counts for every pair of residents in a schedule from a date onward, computed in one pass. Every pair is listed, zeros included, most shared first. " <>
          "Restrict to one class with residency_year; pick another schedule with academic_year. Same counting rule as shared_shifts. " <>
          "Use it for questions about the whole program ('which two residents overlap most', 'who is isolated'). For one resident use shared_shifts_by_coworker.",
        %{
          from: string("Count from this date. " <> @date_desc),
          to: string("Count through this date (inclusive). Defaults to the end of the schedule."),
          residency_year: %{
            type: "integer",
            description: "Residency year 1–4 to restrict the matrix to one class."
          },
          academic_year: %{
            type: "integer",
            description:
              "Schedule start year, e.g. 2026. Defaults to the schedule active on `from`."
          }
        },
        [],
        read_only: true
      ),
      tool(
        "check_coverage",
        "Check a proposed cover",
        "Dry run: could `covering` take `original`'s shift on the dates? Returns the shift, any blocking problems, and an ESTIMATED ACGME 80-hour check (nominal hours per rotation; no shift times exist). Writes nothing.",
        %{
          covering: string("Name of the resident who would cover."),
          original: string("Name of the resident whose shift it is."),
          start_date: string("First day to cover (YYYY-MM-DD)."),
          end_date: string("Last day to cover (YYYY-MM-DD). Defaults to start_date.")
        },
        ["covering", "original", "start_date"],
        read_only: true
      ),
      tool(
        "request_coverage",
        "Request a schedule change",
        "Files a PENDING request for `covering` to take `original`'s shift on the dates. Admins may file any request; other users only when their home resident is one of the two parties. Nothing changes until an admin approves. Run check_coverage first.",
        %{
          covering: string("Name of the resident who will cover."),
          original: string("Name of the resident whose shift it is."),
          start_date: string("First day to cover (YYYY-MM-DD)."),
          end_date: string("Last day to cover (YYYY-MM-DD). Defaults to start_date."),
          note: string("Optional note for the reviewer.")
        },
        ["covering", "original", "start_date"],
        read_only: false
      ),
      tool(
        "list_change_requests",
        "List schedule change requests",
        "Lists change requests visible to the caller: admins see all, others see requests they filed or that involve their home resident. Filter by status.",
        %{
          status: %{
            type: "string",
            enum: ["pending", "approved", "denied", "cancelled"],
            description: "Only requests with this status."
          }
        },
        [],
        read_only: true
      ),
      tool(
        "review_change_request",
        "Approve or deny a change request",
        "Admins only. Approving creates the shift override immediately; denying records the decision.",
        %{
          request_id: %{type: "integer", description: "Id from list_change_requests."},
          decision: %{type: "string", enum: ["approve", "deny"]},
          note: string("Optional note for the requester.")
        },
        ["request_id", "decision"],
        read_only: false
      ),
      tool(
        "cancel_change_request",
        "Cancel a pending change request",
        "Cancels a pending request you filed (admins may cancel any).",
        %{request_id: %{type: "integer", description: "Id from list_change_requests."}},
        ["request_id"],
        read_only: false
      )
    ]
  end

  @doc """
  Executes a tool for the user. Returns `{:ok, result}` where result is the
  MCP `tools/call` result map, or `{:error, :unknown_tool}`.

  Exempt from doctest — most tools hit the database. See `ToolsTest`.
  """
  def call(name, args, %User{} = user) when is_map(args) do
    case dispatch(name, args, user) do
      {:ok, data} -> {:ok, success(data)}
      {:error, :unknown_tool} -> {:error, :unknown_tool}
      {:error, reason} -> {:ok, failure(describe_error(reason))}
    end
  end

  def call(name, _args, user), do: call(name, %{}, user)

  @doc """
  Formats a business error for the model.

      iex> ResidencyScheduleWeb.MCP.Tools.describe_error({:ambiguous_resident, "Nora", ["Nora Kass", "Nora Yale"]})
      "More than one resident matches \\"Nora\\": Nora Kass, Nora Yale. Ask which one and retry with the fuller name."

      iex> ResidencyScheduleWeb.MCP.Tools.describe_error(:forbidden)
      "You do not have permission to do that. Residents may only file requests involving their own home resident; admins may review requests."
  """
  def describe_error({:resident_not_found, name}),
    do:
      "No resident named \"#{name}\" in that schedule. Try find_resident with a different spelling."

  def describe_error({:ambiguous_resident, name, candidates}),
    do:
      "More than one resident matches \"#{name}\": #{Enum.join(candidates, ", ")}. Ask which one and retry with the fuller name."

  def describe_error({:no_rotation_on_date, name, date}),
    do: "#{name} has no rotation on #{Date.to_iso8601(date)}."

  def describe_error(:invalid_date), do: "Dates must be ISO 8601 (YYYY-MM-DD)."

  def describe_error(:unknown_rotation),
    do: "Unknown rotation. Try names like 'strong ob', 'onc', 'gyn', 'night float', 'ambulatory'."

  def describe_error(:no_schedule), do: "No schedule has been imported yet."

  def describe_error({:schedule_not_found, year}),
    do: "No schedule has been imported for the academic year starting #{year}."

  def describe_error(:invalid_academic_year),
    do: "academic_year must be a start year such as 2026."

  def describe_error(:invalid_residency_year), do: "residency_year must be 1, 2, 3, or 4."

  def describe_error(:forbidden),
    do:
      "You do not have permission to do that. Residents may only file requests involving their own home resident; admins may review requests."

  def describe_error(:rotation_not_found), do: "That rotation no longer exists."

  def describe_error(:covering_resident_not_found),
    do: "The covering resident could not be found."

  def describe_error(:covering_is_original), do: "A resident cannot cover their own shift."

  def describe_error(:different_schedules),
    do: "Both residents must be in the same academic-year schedule."

  def describe_error(:dates_outside_rotation),
    do:
      "The dates must fall within a single rotation block of the original resident, with start on or before end."

  def describe_error(:already_covered),
    do: "Someone is already covering that shift on those dates."

  def describe_error(:covering_resident_busy),
    do: "The covering resident is already covering another shift on those dates."

  def describe_error(:duplicate_request),
    do: "A pending request for that shift already overlaps those dates."

  def describe_error(:not_found), do: "No such change request."
  def describe_error(:not_pending), do: "That request has already been decided or cancelled."
  def describe_error(:invalid_decision), do: "decision must be 'approve' or 'deny'."

  def describe_error(:invalid_status),
    do: "status must be pending, approved, denied, or cancelled."

  def describe_error(:invalid_request_id), do: "request_id must be an integer."

  def describe_error(%Ecto.Changeset{} = changeset),
    do: "Invalid request: " <> inspect(changeset.errors)

  def describe_error(other), do: "Request failed: #{inspect(other)}"

  # ── Dispatch ───────────────────────────────────────────────────────────────

  # whoami also reports what this server build serves, so a client holding a
  # stale tool catalogue can prove the mismatch from its own side.
  defp dispatch("whoami", _args, user) do
    with {:ok, identity} <- Assistant.whoami(user) do
      {:ok,
       Map.put(identity, :server, %{
         build: ResidencyScheduleWeb.MCP.Build.sha(),
         tool_count: length(definitions()),
         tools: Enum.map(definitions(), & &1.name)
       })}
    end
  end

  defp dispatch("list_residents", args, _user),
    do:
      Assistant.list_residents(%{
        residency_year: args["residency_year"],
        academic_year: args["academic_year"]
      })

  defp dispatch("shared_shift_matrix", args, _user),
    do:
      Assistant.shared_shift_matrix(%{
        from: args["from"],
        to: args["to"],
        residency_year: args["residency_year"],
        academic_year: args["academic_year"]
      })

  defp dispatch("shared_shifts_by_coworker", args, _user),
    do: Assistant.shared_shifts_by_coworker(args["name"], args["from"], args["to"])

  defp dispatch("find_resident", args, _user),
    do: Assistant.find_resident(args["name"], args["date"])

  defp dispatch("who_is_on", args, _user), do: Assistant.who_is_on(args["rotation"], args["date"])

  defp dispatch("resident_schedule", args, _user),
    do: Assistant.resident_schedule(args["name"], args["from"], args["to"])

  defp dispatch("shifts_remaining", args, _user),
    do: Assistant.shifts_remaining(args["name"], args["from"], args["to"])

  defp dispatch("shared_shifts", args, _user),
    do: Assistant.shared_shifts(args["resident"], args["coworker"], args["from"], args["to"])

  defp dispatch("check_coverage", args, _user),
    do:
      Assistant.check_coverage(
        args["covering"],
        args["original"],
        args["start_date"],
        args["end_date"]
      )

  defp dispatch("request_coverage", args, user),
    do:
      Assistant.request_coverage(
        user,
        args["covering"],
        args["original"],
        args["start_date"],
        args["end_date"],
        args["note"]
      )

  defp dispatch("list_change_requests", args, user) do
    with {:ok, status} <- parse_status(args["status"]) do
      requests =
        user |> ChangeRequests.list_requests(status) |> Enum.map(&Assistant.request_summary/1)

      {:ok, %{requests: requests, count: length(requests)}}
    end
  end

  defp dispatch("review_change_request", args, user) do
    with {:ok, id} <- parse_id(args["request_id"]),
         {:ok, review} <- review_fun(args["decision"]),
         {:ok, request} <- review.(user, id, args["note"]) do
      {:ok, Assistant.request_summary(request)}
    end
  end

  defp dispatch("cancel_change_request", args, user) do
    with {:ok, id} <- parse_id(args["request_id"]),
         {:ok, request} <- ChangeRequests.cancel_request(user, id) do
      {:ok, Assistant.request_summary(ChangeRequests.get_request(request.id))}
    end
  end

  defp dispatch(_name, _args, _user), do: {:error, :unknown_tool}

  defp review_fun("approve"), do: {:ok, &ChangeRequests.approve_request/3}
  defp review_fun("deny"), do: {:ok, &ChangeRequests.deny_request/3}
  defp review_fun(_other), do: {:error, :invalid_decision}

  defp parse_status(nil), do: {:ok, nil}

  defp parse_status(status) when status in ["pending", "approved", "denied", "cancelled"],
    do: {:ok, String.to_existing_atom(status)}

  defp parse_status(_other), do: {:error, :invalid_status}

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_request_id}
    end
  end

  defp parse_id(_id), do: {:error, :invalid_request_id}

  # ── Result shaping ─────────────────────────────────────────────────────────

  defp success(data) do
    %{
      content: [%{type: "text", text: Jason.encode!(data)}],
      structuredContent: data,
      isError: false
    }
  end

  defp failure(message) do
    %{content: [%{type: "text", text: message}], isError: true}
  end

  defp tool(name, title, description, properties, required, read_only: read_only) do
    %{
      name: name,
      title: title,
      description: description,
      inputSchema: %{type: "object", properties: properties, required: required},
      annotations: %{
        readOnlyHint: read_only,
        destructiveHint: false,
        idempotentHint: read_only,
        openWorldHint: false
      }
    }
  end

  defp string(description), do: %{type: "string", description: description}
end
