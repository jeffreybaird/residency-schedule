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

  alias ResidencySchedule.Assistant.{
    DutyHoursCheck,
    LocalDate,
    ResidentResolver,
    RotationAliases,
    SharedShiftMatrix
  }

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
  Lists residents in one schedule. `opts` may carry `:academic_year` (start
  year such as 2026; defaults to the schedule active today) and
  `:residency_year` (1–4) to keep only that class.

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def list_residents(opts \\ %{}) do
    with {:ok, schedule} <- schedule_for_opts(opts),
         {:ok, residency_year} <- parse_residency_year(opts[:residency_year]) do
      residents =
        case residency_year do
          nil -> Residents.list_residents_for_schedule(schedule.id)
          year -> Residents.list_residents_by_year(schedule.id, year)
        end

      {:ok,
       %{
         schedule: schedule.label,
         academic_year: schedule.academic_year,
         residency_year: residency_year,
         count: length(residents),
         residents: Enum.map(residents, &resident_summary(&1, schedule))
       }}
    end
  end

  @doc """
  Describes the user's own account, home resident, and the academic years
  loaded with the dates each covers.

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def whoami(%User{} = user) do
    {:ok,
     %{
       email: user.email,
       role: user.role,
       home_resident: home_summary(user.home_resident_id),
       today: LocalDate.today(),
       schedules: Enum.map(Schedules.list_schedule_ranges(), &schedule_range_summary/1)
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

  # ── Shifts ─────────────────────────────────────────────────────────────────

  @doc """
  Counts a resident's working days (shifts), with coverage applied, from
  `from` (default today) through `to` (default: no end). Every academic year
  the person appears in is counted, so a `from` before their first year
  gives their whole residency. Every rotation except vacation and post-call
  is a shift, float included. Days someone else is covering are not the
  resident's shifts; days they cover for someone else are.

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def shifts_remaining(name, from \\ nil, to \\ nil) do
    with {:ok, from} <- LocalDate.parse(from),
         {:ok, to} <- LocalDate.parse_optional(to),
         {:ok, schedule} <- schedule_for(from),
         {:ok, resident} <- resolve(name, schedule.id) do
      by_year =
        resident
        |> appearances()
        |> Enum.map(&{&1, working_days(&1, from, to)})
        |> Enum.reject(fn {_appearance, days} -> days == [] end)

      days = Enum.flat_map(by_year, fn {_appearance, days} -> days end)

      {:ok,
       %{
         resident: resident_summary(resident, schedule),
         from: from,
         to: to,
         count: length(days),
         by_rotation: count_by_rotation(days),
         by_year: Enum.map(by_year, &year_count/1),
         counting_rule: %{
           counts: "every working day, including float and solo rotations",
           not_shifts: Rotations.non_working_rotation_types()
         }
       }}
    end
  end

  @doc """
  Counts the days two residents are on the same shared service together, with
  coverage applied, from `from` (default today) through `to` (default end of
  schedule). Only rotations that can hold more than one resident count (see
  `Rotations.shared_service?/1`).

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
         dates: Enum.map(days, & &1.date),
         counting_rule: shared_counting_rule()
       }}
    end
  end

  @doc """
  Shared-shift counts between one resident and every other resident in the
  schedule, from `from` (default today) through `to` (default end of
  schedule), most shared first. Coworkers with zero shared shifts are
  included so "who do I never work with" is answerable.

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def shared_shifts_by_coworker(name, from \\ nil, to \\ nil) do
    with {:ok, from} <- LocalDate.parse(from),
         {:ok, to} <- LocalDate.parse_optional(to),
         {:ok, schedule} <- schedule_for(from),
         {:ok, resident} <- resolve(name, schedule.id) do
      residents = Residents.list_residents_for_schedule(schedule.id)
      counts = pair_counts_for_schedule(schedule.id, from, to)

      coworkers =
        residents
        |> Enum.reject(&(&1.id == resident.id))
        |> Enum.map(&coworker_share(counts, resident, &1))
        |> Enum.sort_by(&{-&1.count, &1.coworker.residency_year, &1.coworker.position_code})

      {:ok,
       %{
         resident: resident_summary(resident, schedule),
         from: from,
         to: to,
         coworkers: coworkers,
         counting_rule: shared_counting_rule()
       }}
    end
  end

  @doc """
  Shared-shift counts for every pair of residents in a schedule, computed in
  one pass. `opts` may carry `:from` (default today), `:to` (default end of
  schedule), `:academic_year` (schedule start year, default the schedule
  active on `from`), and `:residency_year` to restrict the matrix to one
  class. Every pair is listed, zeros included, most shared first.

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def shared_shift_matrix(opts \\ %{}) do
    with {:ok, from} <- LocalDate.parse(opts[:from]),
         {:ok, to} <- LocalDate.parse_optional(opts[:to]),
         {:ok, schedule} <- schedule_for_opts(opts, from),
         {:ok, residency_year} <- parse_residency_year(opts[:residency_year]) do
      residents =
        schedule.id
        |> Residents.list_residents_for_schedule()
        |> Enum.filter(&(residency_year == nil or &1.residency_year == residency_year))

      counts = pair_counts_for_schedule(schedule.id, from, to)

      pairs =
        for {a, i} <- Enum.with_index(residents),
            b <- Enum.drop(residents, i + 1) do
          shared = SharedShiftMatrix.lookup(counts, a.id, b.id)

          %{
            resident: resident_summary(a, nil),
            coworker: resident_summary(b, nil),
            count: shared.count,
            by_rotation: by_rotation_list(shared.by_rotation)
          }
        end

      {:ok,
       %{
         schedule: schedule.label,
         academic_year: schedule.academic_year,
         residency_year: residency_year,
         from: from,
         to: to,
         residents: Enum.map(residents, &resident_summary(&1, nil)),
         pairs: Enum.sort_by(pairs, &(-&1.count)),
         counting_rule: shared_counting_rule()
       }}
    end
  end

  # ── Resident schedule ──────────────────────────────────────────────────────

  @doc """
  A resident's effective rotation segments (coverage applied) overlapping the
  range `from` (default today) through `to` (default: no end), across every
  academic year the person appears in. Each segment names its schedule.

  Exempt from doctest — hits the database. See `AssistantTest`.
  """
  def resident_schedule(name, from \\ nil, to \\ nil) do
    with {:ok, from} <- LocalDate.parse(from),
         {:ok, to} <- LocalDate.parse_optional(to),
         {:ok, schedule} <- schedule_for(from),
         {:ok, resident} <- resolve(name, schedule.id) do
      segments =
        resident
        |> appearances()
        |> Enum.flat_map(&segments_in_range(&1, from, to))
        |> Enum.sort_by(& &1.start_date, Date)

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

  # ── Private: shared shifts ─────────────────────────────────────────────────

  defp pair_counts_for_schedule(schedule_id, from, to) do
    schedule_id
    |> Rotations.effective_segments_for_schedule()
    |> Map.new(fn {id, segments} ->
      {id, segments |> SharedShiftMatrix.cells() |> clip_cells(from, to)}
    end)
    |> SharedShiftMatrix.pair_counts()
  end

  defp clip_cells(cells, from, to),
    do: Enum.filter(cells, fn {date, _type} -> within?(date, from, to) end)

  defp coworker_share(counts, resident, coworker) do
    shared = SharedShiftMatrix.lookup(counts, resident.id, coworker.id)

    %{
      coworker: resident_summary(coworker, nil),
      count: shared.count,
      by_rotation: by_rotation_list(shared.by_rotation)
    }
  end

  defp by_rotation_list(by_rotation) do
    by_rotation
    |> Enum.map(fn {type, days} ->
      %{rotation_type: type, rotation_label: Rotations.rotation_type_label(type), days: days}
    end)
    |> Enum.sort_by(&(-&1.days))
  end

  defp shared_counting_rule do
    %{
      counts: "days both residents are on the same shared service",
      working_days_not_shared: Rotations.solo_rotation_types(),
      not_shifts: Rotations.non_working_rotation_types()
    }
  end

  defp schedule_for_opts(opts, fallback_date \\ LocalDate.today())

  defp schedule_for_opts(%{academic_year: year}, _fallback_date) when not is_nil(year) do
    with {:ok, year} <- parse_integer(year, :invalid_academic_year) do
      case Schedules.get_by_year(year) do
        nil -> {:error, {:schedule_not_found, year}}
        schedule -> {:ok, schedule}
      end
    end
  end

  defp schedule_for_opts(_opts, fallback_date), do: schedule_for(fallback_date)

  defp parse_residency_year(nil), do: {:ok, nil}

  defp parse_residency_year(year) do
    case parse_integer(year, :invalid_residency_year) do
      {:ok, int} when int in 1..4 -> {:ok, int}
      {:ok, _out_of_range} -> {:error, :invalid_residency_year}
      error -> error
    end
  end

  defp parse_integer(value, _error) when is_integer(value), do: {:ok, value}

  defp parse_integer(value, error) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> {:error, error}
    end
  end

  defp parse_integer(_value, error), do: {:error, error}

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

  defp home_summary(person_id) do
    case Residents.latest_appearance_for_person(person_id) do
      nil -> nil
      appearance -> resident_summary(appearance, appearance.schedule)
    end
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

  defp schedule_range_summary(range) do
    %{
      academic_year: range.academic_year,
      label: range.label,
      start_date: range.start_date,
      end_date: range.end_date
    }
  end

  defp appearances(resident), do: Residents.list_appearances_for_person(resident.resident_id)

  defp working_days(appearance, from, to) do
    appearance.id
    |> Rotations.effective_segments_for_resident()
    |> Enum.reject(&(&1.covered_by != nil))
    |> Enum.flat_map(&segment_dates/1)
    |> Enum.filter(&(within?(&1.date, from, to) and Rotations.working_day?(&1.rotation_type)))
  end

  defp year_count({appearance, days}) do
    %{
      academic_year: appearance.schedule.academic_year,
      schedule: appearance.schedule.label,
      residency_year: appearance.residency_year,
      position_code: appearance.position_code,
      days: length(days)
    }
  end

  defp segments_in_range(appearance, from, to) do
    appearance.id
    |> Rotations.effective_segments_for_resident()
    |> Enum.filter(&overlaps?(&1, from, to))
    |> Enum.map(&Map.put(segment_summary(&1), :schedule, appearance.schedule.label))
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

  defp segment_dates(segment) do
    segment.start_date
    |> Date.range(segment.end_date)
    |> Enum.map(&%{date: &1, rotation_type: segment.rotation_type})
  end

  defp within?(date, from, nil), do: Date.compare(date, from) != :lt
  defp within?(date, from, to), do: within?(date, from, nil) and Date.compare(date, to) != :gt

  defp overlaps?(segment, from, to) do
    Date.compare(segment.end_date, from) != :lt and
      (to == nil or Date.compare(segment.start_date, to) != :gt)
  end
end
