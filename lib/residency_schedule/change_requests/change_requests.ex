defmodule ResidencySchedule.ChangeRequests do
  @moduledoc """
  Schedule change requests: a resident (or admin) asks for one resident to
  cover part of another's rotation. Requests are pending until an admin
  approves them, at which point a `ShiftOverride` is created and the change
  takes effect everywhere the schedule is rendered.

  Permission rules:
  - Admins may file, approve, deny, and cancel any request.
  - Any other approved user may file a request only when their home resident
    is the person being covered or the person covering.
  - A requester may cancel their own pending request.

  Every state change is broadcast on `topic/0` as
  `{:change_request, event, request}` with event one of `:filed`,
  `:approved`, `:denied`, or `:cancelled`, so live pages can refresh.
  """
  import Ecto.Query

  alias ResidencySchedule.Accounts.User
  alias ResidencySchedule.ChangeRequests.ChangeRequest
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents.ScheduleResident
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.ShiftOverrides

  @topic "change_requests"

  # ── PubSub ─────────────────────────────────────────────────────────────────

  @doc """
  The PubSub topic change-request events are broadcast on.

      iex> ResidencySchedule.ChangeRequests.topic()
      "change_requests"
  """
  def topic, do: @topic

  @doc """
  Subscribes the calling process to change-request events.

  Exempt from doctest — touches the PubSub server. See `ChangeRequestsTest`.
  """
  def subscribe, do: Phoenix.PubSub.subscribe(ResidencySchedule.PubSub, @topic)

  # ── Filing ─────────────────────────────────────────────────────────────────

  @doc """
  Files a coverage request. `attrs` needs `:rotation_id`,
  `:covering_schedule_resident_id`, `:start_date`, `:end_date`, and an
  optional `:note`. Returns `{:ok, request}` or `{:error, reason}` where
  reason is one of `:rotation_not_found`, `:covering_resident_not_found`,
  `:covering_is_original`, `:different_schedules`, `:dates_outside_rotation`,
  `:already_covered`, `:covering_resident_busy`, `:duplicate_request`,
  `:forbidden`, or a changeset.

  Exempt from doctest — hits the database. See `ChangeRequestsTest`.
  """
  def request_coverage(%User{} = user, attrs) do
    with {:ok, rotation, covering} <- validate_coverage(attrs),
         :ok <- authorize_filing(user, rotation.schedule_resident, covering) do
      user
      |> insert_request(rotation, covering, attrs)
      |> broadcast(:filed)
    end
  end

  @doc """
  Runs every filing check except permission, without writing anything. Used
  for dry-run questions ("could Clare cover this?"). Returns
  `{:ok, rotation, covering_resident}` or `{:error, reason}` with the same
  reasons as `request_coverage/2`.

  Exempt from doctest — hits the database. See `ChangeRequestsTest`.
  """
  def validate_coverage(attrs) do
    with {:ok, rotation} <- fetch_rotation(attrs[:rotation_id]),
         {:ok, covering} <- fetch_schedule_resident(attrs[:covering_schedule_resident_id]),
         :ok <- ensure_distinct(rotation, covering),
         :ok <- ensure_same_schedule(rotation, covering),
         :ok <- ensure_dates_within_rotation(rotation, attrs[:start_date], attrs[:end_date]),
         :ok <- ensure_not_already_covered(rotation, attrs[:start_date], attrs[:end_date]),
         :ok <- ensure_covering_free(covering, attrs[:start_date], attrs[:end_date]),
         :ok <- ensure_no_open_duplicate(rotation, attrs[:start_date], attrs[:end_date]) do
      {:ok, rotation, covering}
    end
  end

  # ── Review ─────────────────────────────────────────────────────────────────

  @doc """
  Approves a pending request (admins only). Creates the `ShiftOverride` and
  marks the request approved in one transaction. Errors: `:forbidden`,
  `:not_found`, `:not_pending`, or a changeset.

  Exempt from doctest — hits the database. See `ChangeRequestsTest`.
  """
  def approve_request(%User{} = admin, request_id, note \\ nil) do
    with :ok <- ensure_admin(admin),
         {:ok, request} <- fetch_pending(request_id) do
      fn -> approve_in_transaction(admin, request, note) end
      |> Repo.transaction()
      |> broadcast(:approved)
    end
  end

  @doc """
  Denies a pending request (admins only). Errors: `:forbidden`, `:not_found`,
  `:not_pending`, or a changeset.

  Exempt from doctest — hits the database. See `ChangeRequestsTest`.
  """
  def deny_request(%User{} = admin, request_id, note \\ nil) do
    with :ok <- ensure_admin(admin),
         {:ok, request} <- fetch_pending(request_id) do
      request
      |> ChangeRequest.review_changeset(review_attrs(admin, :denied, note))
      |> Repo.update()
      |> reload_request()
      |> broadcast(:denied)
    end
  end

  @doc """
  Cancels a pending request. Allowed for the requester or an admin. Errors:
  `:forbidden`, `:not_found`, `:not_pending`.

  Exempt from doctest — hits the database. See `ChangeRequestsTest`.
  """
  def cancel_request(%User{} = user, request_id) do
    with {:ok, request} <- fetch_pending(request_id),
         :ok <- authorize_cancel(user, request) do
      request
      |> Ecto.Changeset.change(status: :cancelled)
      |> Repo.update()
      |> broadcast(:cancelled)
    end
  end

  # ── Reading ────────────────────────────────────────────────────────────────

  @doc """
  Fetches one request with its rotation (and original resident), covering
  resident, and requester preloaded, or nil.

  Exempt from doctest — hits the database.
  """
  def get_request(id) do
    base_query()
    |> where([r], r.id == ^id)
    |> Repo.one()
  end

  @doc """
  Lists requests visible to the user, newest first, optionally filtered by
  status. Admins see every request; other users see requests they filed or
  that involve their home resident (as the covered or covering person).

  Exempt from doctest — hits the database. See `ChangeRequestsTest`.
  """
  def list_requests(%User{} = user, status \\ nil) do
    base_query()
    |> filter_status(status)
    |> filter_visible_to(user)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> Repo.all()
  end

  @doc """
  Returns true when the user may file a coverage request between the two
  schedule residents: admins always; other users only when their home
  resident is the same person as either party.

      iex> admin = %ResidencySchedule.Accounts.User{role: :admin}
      iex> ResidencySchedule.ChangeRequests.may_file?(admin, 1, 2, nil)
      true

      iex> user = %ResidencySchedule.Accounts.User{role: :resident}
      iex> ResidencySchedule.ChangeRequests.may_file?(user, 1, 2, 2)
      true

      iex> user = %ResidencySchedule.Accounts.User{role: :resident}
      iex> ResidencySchedule.ChangeRequests.may_file?(user, 1, 2, 3)
      false
  """
  def may_file?(%User{role: :admin}, _original_person, _covering_person, _home_person), do: true
  def may_file?(_user, _original_person, _covering_person, nil), do: false

  def may_file?(_user, original_person, covering_person, home_person) do
    home_person in [original_person, covering_person]
  end

  # ── Private: broadcasting ──────────────────────────────────────────────────

  defp reload_request({:ok, request}), do: {:ok, get_request(request.id)}
  defp reload_request(error), do: error

  defp broadcast({:ok, request} = result, event) do
    Phoenix.PubSub.broadcast(ResidencySchedule.PubSub, @topic, {:change_request, event, request})
    result
  end

  defp broadcast(error, _event), do: error

  # ── Private: filing checks ─────────────────────────────────────────────────

  defp fetch_rotation(nil), do: {:error, :rotation_not_found}

  defp fetch_rotation(id) do
    case Rotations.get_rotation(id) do
      nil -> {:error, :rotation_not_found}
      rotation -> {:ok, rotation}
    end
  end

  defp fetch_schedule_resident(nil), do: {:error, :covering_resident_not_found}

  defp fetch_schedule_resident(id) do
    case Repo.one(from(sr in ScheduleResident.with_name_query(), where: sr.id == ^id)) do
      nil -> {:error, :covering_resident_not_found}
      resident -> {:ok, resident}
    end
  end

  defp ensure_distinct(%Rotation{schedule_resident_id: id}, %ScheduleResident{id: id}),
    do: {:error, :covering_is_original}

  defp ensure_distinct(_rotation, _covering), do: :ok

  defp ensure_same_schedule(%Rotation{schedule_resident: %{schedule_id: sid}}, %{schedule_id: sid}),
       do: :ok

  defp ensure_same_schedule(_rotation, _covering), do: {:error, :different_schedules}

  defp ensure_dates_within_rotation(
         %Rotation{} = rotation,
         %Date{} = start_date,
         %Date{} = end_date
       ) do
    if Date.compare(start_date, rotation.start_date) != :lt and
         Date.compare(end_date, rotation.end_date) != :gt and
         Date.compare(start_date, end_date) != :gt do
      :ok
    else
      {:error, :dates_outside_rotation}
    end
  end

  defp ensure_dates_within_rotation(_rotation, _start, _end),
    do: {:error, :dates_outside_rotation}

  defp ensure_not_already_covered(rotation, start_date, end_date) do
    if ShiftOverrides.rotation_covered_in_range?(rotation.id, start_date, end_date),
      do: {:error, :already_covered},
      else: :ok
  end

  defp ensure_covering_free(covering, start_date, end_date) do
    if ShiftOverrides.resident_covering_in_range?(covering.id, start_date, end_date),
      do: {:error, :covering_resident_busy},
      else: :ok
  end

  defp ensure_no_open_duplicate(rotation, start_date, end_date) do
    exists =
      from(r in ChangeRequest,
        where: r.rotation_id == ^rotation.id and r.status == :pending,
        where: r.start_date <= ^end_date and r.end_date >= ^start_date
      )
      |> Repo.exists?()

    if exists, do: {:error, :duplicate_request}, else: :ok
  end

  defp authorize_filing(user, original, covering) do
    if may_file?(user, original.resident_id, covering.resident_id, home_person_id(user)),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp home_person_id(%User{home_resident_id: person_id}), do: person_id

  defp insert_request(user, rotation, covering, attrs) do
    %ChangeRequest{}
    |> ChangeRequest.changeset(%{
      rotation_id: rotation.id,
      covering_schedule_resident_id: covering.id,
      requested_by_user_id: user.id,
      start_date: attrs[:start_date],
      end_date: attrs[:end_date],
      note: attrs[:note]
    })
    |> Repo.insert()
    |> case do
      {:ok, request} -> {:ok, get_request(request.id)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # ── Private: review ────────────────────────────────────────────────────────

  defp ensure_admin(%User{role: :admin}), do: :ok
  defp ensure_admin(_user), do: {:error, :forbidden}

  defp fetch_pending(id) do
    case get_request(id) do
      nil -> {:error, :not_found}
      %ChangeRequest{status: :pending} = request -> {:ok, request}
      _request -> {:error, :not_pending}
    end
  end

  defp approve_in_transaction(admin, request, note) do
    with {:ok, override} <- create_override(request),
         {:ok, approved} <- mark_approved(admin, request, override, note) do
      get_request(approved.id)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp create_override(request) do
    ShiftOverrides.create_override(%{
      rotation_id: request.rotation_id,
      covering_schedule_resident_id: request.covering_schedule_resident_id,
      override_start_date: request.start_date,
      override_end_date: request.end_date
    })
  end

  defp mark_approved(admin, request, override, note) do
    request
    |> ChangeRequest.review_changeset(
      review_attrs(admin, :approved, note)
      |> Map.put(:shift_override_id, override.id)
    )
    |> Repo.update()
  end

  defp review_attrs(admin, status, note) do
    %{
      status: status,
      reviewed_by_user_id: admin.id,
      reviewed_at: DateTime.utc_now(:second),
      review_note: note
    }
  end

  defp authorize_cancel(%User{role: :admin}, _request), do: :ok
  defp authorize_cancel(%User{id: id}, %ChangeRequest{requested_by_user_id: id}), do: :ok
  defp authorize_cancel(_user, _request), do: {:error, :forbidden}

  # ── Private: reading ───────────────────────────────────────────────────────

  defp base_query do
    sr_query = ScheduleResident.with_name_query()

    from(r in ChangeRequest,
      preload: [
        rotation: [schedule_resident: ^sr_query],
        covering_schedule_resident: ^sr_query,
        requested_by_user: [],
        reviewed_by_user: []
      ]
    )
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: where(query, [r], r.status == ^status)

  defp filter_visible_to(query, %User{role: :admin}), do: query

  defp filter_visible_to(query, %User{} = user) do
    case home_person_id(user) do
      nil ->
        where(query, [r], r.requested_by_user_id == ^user.id)

      person_id ->
        query
        |> join(:inner, [r], rot in assoc(r, :rotation), as: :rot)
        |> join(:inner, [rot: rot], orig in assoc(rot, :schedule_resident), as: :orig)
        |> join(:inner, [r], cov in assoc(r, :covering_schedule_resident), as: :cov)
        |> where(
          [r, orig: orig, cov: cov],
          r.requested_by_user_id == ^user.id or orig.resident_id == ^person_id or
            cov.resident_id == ^person_id
        )
    end
  end
end
