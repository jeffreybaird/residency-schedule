defmodule ResidencySchedule.Assistant do
  @moduledoc """
  Answers the questions the MCP tools expose, in terms of names and dates
  rather than ids: who is on a service, how many shifts two residents share,
  what a resident's effective schedule looks like, and whether a proposed
  cover is valid and within duty-hour limits.

  Every function returns `{:ok, map}` with JSON-ready values, or
  `{:error, reason}` where reason is an atom or a tagged tuple such as
  `{:resident_not_found, "Tiff"}` or `{:ambiguous_resident, "Nora", ["Nora", "Nora Kass"]}`.
  """

  alias ResidencySchedule.Accounts.User
  alias ResidencySchedule.Assistant.{DutyHoursCheck, LocalDate, ResidentResolver, RotationAliases}
  alias ResidencySchedule.{ChangeRequests, Residents, Rotations, Schedules, ShiftOverrides}

  # ── Residents ──────────────────────────────────────────────────────────────

  @doc """
  Finds one resident by name in the schedule active on `date` (default today).

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def find_resident(name, date \\ nil) do
    with {:ok, date} <- LocalDate.parse(date),
         {:ok, schedule} <- schedule_for(date),
         {:ok, resident} <- resolve(name, schedule.id) do
      {:ok, resident_summary(resident, schedule)}
    end
  end

  @doc """
  Describes the user's own account and home resident.

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def whoami(%User{} = user) do
    {:ok,
     %{
       email: user.email,
       role: user.role,
       home_resident: home_summary(user.home_resident_id),
       today: LocalDate.today()
     }}
  end

  # ── Who is on ──────────────────────────────────────────────────────────────

  @doc """
  Lists who is effectively working a rotation on a date (default today),
  with coverage applied. On weekends, the weekend counterparts of a weekday
  service are included.

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def who_is_on(rotation_text, date \\ nil) do
    with {:ok, date} <- LocalDate.parse(date),
         {:ok, rotation_type} <- RotationAliases.resolve(rotation_text),
         {:ok, schedule} <- schedule_for(date) do
      types = types_for_day(rotation_type, date)

      assignments =
        date
        |> effective_assignments_on(schedule.id)
        |> Enum.filter(&(&1.rotation_type in types and not &1.overridden))
        |> Enum.map(&assignment_summary/1)

      {:ok,
       %{
         date: date,
         schedule: schedule.label,
         rotation_type: rotation_type,
         rotation_label: Rotations.rotation_type_label(rotation_type),
         rotation_types_included: types,
         assignments: assignments
       }}
    end
  end

  # ── Shared shifts ──────────────────────────────────────────────────────────

  @doc """
  Counts the days two residents are on the same service together, with
  coverage applied, from `from` (default today) through `to` (default end of
  schedule). Ambulatory, elective, float, post-call, and vacation never count.

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def shared_shifts(name_a, name_b, from \\ nil, to \\ nil) do
    with {:ok, from} <- LocalDate.parse(from),
         {:ok, to} <- LocalDate.parse_optional(to),
         {:ok, schedule} <- schedule_for(from),
         {:ok, a} <- resolve(name_a, schedule.id),
         {:ok, b} <- resolve(name_b, schedule.id) do
      days =
        a.id
        |> Rotations.list_effective_co_service_days(b.id)
        |> Enum.filter(&within?(&1.date, from, to))

      {:ok,
       %{
         resident: resident_summary(a, schedule),
         coworker: resident_summary(b, schedule),
         from: from,
         to: to,
         count: length(days),
         by_rotation: count_by_rotation(days),
         dates: Enum.map(days, & &1.date)
       }}
    end
  end

  # ── Resident schedule ──────────────────────────────────────────────────────

  @doc """
  A resident's effective rotation segments (coverage applied) overlapping the
  range `from` (default today) through `to` (default end of schedule).

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def resident_schedule(name, from \\ nil, to \\ nil) do
    with {:ok, from} <- LocalDate.parse(from),
         {:ok, to} <- LocalDate.parse_optional(to),
         {:ok, schedule} <- schedule_for(from),
         {:ok, resident} <- resolve(name, schedule.id) do
      segments =
        resident.id
        |> Rotations.effective_segments_for_resident()
        |> Enum.filter(&overlaps?(&1, from, to))
        |> Enum.map(&segment_summary/1)

      {:ok,
       %{resident: resident_summary(resident, schedule), from: from, to: to, segments: segments}}
    end
  end

  # ── Coverage ───────────────────────────────────────────────────────────────

  @doc """
  Dry run: could `covering` cover `original`'s shift on the inclusive date
  range (end defaults to start)? Reports the shift, every filing problem, and
  the estimated duty-hour impact. Writes nothing.

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def check_coverage(covering_name, original_name, start_date, end_date \\ nil) do
    with {:ok, plan} <- build_coverage_plan(covering_name, original_name, start_date, end_date) do
      {:ok, describe_plan(plan)}
    end
  end

  @doc """
  Files a pending coverage request on behalf of the user, subject to
  `ChangeRequests` permission rules. Returns the request summary.

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def request_coverage(
        %User{} = user,
        covering_name,
        original_name,
        start_date,
        end_date \\ nil,
        note \\ nil
      ) do
    with {:ok, plan} <- build_coverage_plan(covering_name, original_name, start_date, end_date),
         {:ok, request} <- ChangeRequests.request_coverage(user, Map.put(plan.attrs, :note, note)) do
      {:ok, request_summary(request)}
    end
  end

  @doc """
  Summarizes a change request for tool output.

  Exempt from doctest — the request carries preloaded associations. See `AssistantTest`.
  """
  def request_summary(request) do
    %{
      id: request.id,
      status: request.status,
      rotation_type: request.rotation.rotation_type,
      rotation_label: Rotations.rotation_type_label(request.rotation.rotation_type),
      original_resident: resident_summary(request.rotation.schedule_resident, nil),
      covering_resident: resident_summary(request.covering_schedule_resident, nil),
      start_date: request.start_date,
      end_date: request.end_date,
      note: request.note,
      requested_by: request.requested_by_user && request.requested_by_user.email,
      reviewed_by: request.reviewed_by_user && request.reviewed_by_user.email,
      reviewed_at: request.reviewed_at,
      review_note: request.review_note,
      requested_at: request.inserted_at
    }
  end

  @doc """
  Finds the schedule active on a date, falling back to the latest imported
  schedule when the date is outside every schedule.

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def schedule_for(%Date{} = date) do
    case Schedules.get_schedule_for_date(date) || Schedules.latest_schedule() do
      nil -> {:error, :no_schedule}
      schedule -> {:ok, schedule}
    end
  end

  # ── Private: resolution ────────────────────────────────────────────────────

  defp resolve(name, schedule_id) do
    case ResidentResolver.resolve(name, schedule_id) do
      {:ok, resident} ->
        {:ok, resident}

      {:error, :not_found} ->
        {:error, {:resident_not_found, name}}

      {:error, {:ambiguous, many}} ->
        {:error, {:ambiguous_resident, name, Enum.map(many, & &1.name)}}
    end
  end

  defp build_coverage_plan(covering_name, original_name, start_date, end_date) do
    with {:ok, start_date} <- LocalDate.parse(start_date),
         {:ok, end_date} <- parse_end_date(end_date, start_date),
         {:ok, schedule} <- schedule_for(start_date),
         {:ok, covering} <- resolve(covering_name, schedule.id),
         {:ok, original} <- resolve(original_name, schedule.id),
         {:ok, rotation} <- rotation_on(original, start_date) do
      {:ok,
       %{
         schedule: schedule,
         covering: covering,
         original: original,
         rotation: rotation,
         attrs: %{
           rotation_id: rotation.id,
           covering_schedule_resident_id: covering.id,
           start_date: start_date,
           end_date: end_date
         }
       }}
    end
  end

  defp parse_end_date(nil, start_date), do: {:ok, start_date}
  defp parse_end_date("", start_date), do: {:ok, start_date}
  defp parse_end_date(text, _start_date), do: LocalDate.parse(text)

  defp rotation_on(resident, date) do
    case Rotations.get_rotation_for_resident_on_date(resident.id, date) do
      nil -> {:error, {:no_rotation_on_date, resident.name, date}}
      rotation -> {:ok, rotation}
    end
  end

  defp describe_plan(plan) do
    problems =
      case ChangeRequests.validate_coverage(plan.attrs) do
        {:ok, _rotation, _covering} -> []
        {:error, reason} -> [reason]
      end

    duty_hours =
      DutyHoursCheck.check(
        plan.covering.id,
        plan.rotation.rotation_type,
        plan.attrs.start_date,
        plan.attrs.end_date
      )

    %{
      covering_resident: resident_summary(plan.covering, plan.schedule),
      original_resident: resident_summary(plan.original, plan.schedule),
      shift: %{
        rotation_id: plan.rotation.id,
        rotation_type: plan.rotation.rotation_type,
        rotation_label: Rotations.rotation_type_label(plan.rotation.rotation_type),
        rotation_start_date: plan.rotation.start_date,
        rotation_end_date: plan.rotation.end_date
      },
      start_date: plan.attrs.start_date,
      end_date: plan.attrs.end_date,
      can_file: problems == [],
      problems: problems,
      duty_hours: duty_hours
    }
  end

  # ── Private: day assignments ───────────────────────────────────────────────

  defp types_for_day(rotation_type, date) do
    if Date.day_of_week(date) in [6, 7],
      do: [rotation_type | RotationAliases.weekend_counterparts(rotation_type)],
      else: [rotation_type]
  end

  defp effective_assignments_on(date, schedule_id) do
    rotations = Rotations.list_rotations_for_date(date, schedule_id)
    overrides = ShiftOverrides.list_overrides_for_schedule_in_range(schedule_id, date, date)
    Rotations.effective_day_assignments(rotations, overrides)
  end

  defp assignment_summary(row) do
    %{
      name: row.resident.name,
      position_code: row.resident.position_code,
      residency_year: row.resident.residency_year,
      rotation_type: row.rotation_type,
      is_coverage: row.is_coverage
    }
  end

  # ── Private: summaries ─────────────────────────────────────────────────────

  defp resident_summary(resident, schedule) do
    %{
      id: resident.id,
      name: resident.name,
      position_code: resident.position_code,
      residency_year: resident.residency_year,
      schedule: schedule && schedule.label
    }
  end

  defp home_summary(nil), do: nil

  defp home_summary(schedule_resident_id) do
    resident_summary(Residents.get_resident!(schedule_resident_id), nil)
  end

  defp segment_summary(segment) do
    %{
      rotation_type: segment.rotation_type,
      rotation_label: Rotations.rotation_type_label(segment.rotation_type),
      start_date: segment.start_date,
      end_date: segment.end_date,
      is_coverage: segment.is_coverage,
      covered_by: segment.covered_by && segment.covered_by.name,
      covering_for: segment.original_resident && segment.original_resident.name
    }
  end

  defp count_by_rotation(days) do
    days
    |> Enum.group_by(& &1.rotation_type)
    |> Enum.map(fn {type, entries} ->
      %{
        rotation_type: type,
        rotation_label: Rotations.rotation_type_label(type),
        days: length(entries)
      }
    end)
    |> Enum.sort_by(&(-&1.days))
  end

  defp within?(date, from, nil), do: Date.compare(date, from) != :lt
  defp within?(date, from, to), do: within?(date, from, nil) and Date.compare(date, to) != :gt

  defp overlaps?(segment, from, to) do
    Date.compare(segment.end_date, from) != :lt and
      (to == nil or Date.compare(segment.start_date, to) != :gt)
  end
end
