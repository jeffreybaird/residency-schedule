defmodule ResidencySchedule.ChangeRequestsTest do
  use ResidencySchedule.DataCase, async: true

  import ResidencySchedule.ScheduleFixtures

  alias ResidencySchedule.{ChangeRequests, Rotations, ShiftOverrides}
  alias ResidencySchedule.ChangeRequests.ChangeRequest

  doctest ChangeRequests
  doctest ChangeRequest

  setup do
    fixtures = seed_mini_schedule()
    tiff_ob = rotation_on(fixtures.tiff, ~D[2026-07-15])

    Map.merge(fixtures, %{
      tiff_ob: tiff_ob,
      clare_user: resident_user(fixtures.clare),
      tiff_user: resident_user(fixtures.tiff),
      mary_user: resident_user(fixtures.mary),
      admin: admin_user(),
      stranger: unlinked_user()
    })
  end

  defp attrs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        rotation_id: ctx.tiff_ob.id,
        covering_schedule_resident_id: ctx.clare.id,
        start_date: ~D[2026-07-15],
        end_date: ~D[2026-07-16],
        note: "swap"
      },
      overrides
    )
  end

  describe "request_coverage/2" do
    test "covering resident may file", ctx do
      assert {:ok, request} = ChangeRequests.request_coverage(ctx.clare_user, attrs(ctx))
      assert request.status == :pending
      assert request.rotation.schedule_resident.name == "Tiff"
      assert request.covering_schedule_resident.name == "Clare"
      assert request.note == "swap"
    end

    test "covered resident may file", ctx do
      assert {:ok, _} = ChangeRequests.request_coverage(ctx.tiff_user, attrs(ctx))
    end

    test "admin may file", ctx do
      assert {:ok, _} = ChangeRequests.request_coverage(ctx.admin, attrs(ctx))
    end

    test "uninvolved resident is forbidden", ctx do
      assert {:error, :forbidden} = ChangeRequests.request_coverage(ctx.mary_user, attrs(ctx))
    end

    test "user without a home resident is forbidden", ctx do
      assert {:error, :forbidden} = ChangeRequests.request_coverage(ctx.stranger, attrs(ctx))
    end

    test "unknown rotation", ctx do
      assert {:error, :rotation_not_found} =
               ChangeRequests.request_coverage(ctx.admin, attrs(ctx, %{rotation_id: 0}))

      assert {:error, :rotation_not_found} =
               ChangeRequests.request_coverage(ctx.admin, attrs(ctx, %{rotation_id: nil}))
    end

    test "unknown covering resident", ctx do
      assert {:error, :covering_resident_not_found} =
               ChangeRequests.request_coverage(
                 ctx.admin,
                 attrs(ctx, %{covering_schedule_resident_id: 0})
               )

      assert {:error, :covering_resident_not_found} =
               ChangeRequests.request_coverage(
                 ctx.admin,
                 attrs(ctx, %{covering_schedule_resident_id: nil})
               )
    end

    test "covering yourself", ctx do
      assert {:error, :covering_is_original} =
               ChangeRequests.request_coverage(
                 ctx.admin,
                 attrs(ctx, %{covering_schedule_resident_id: ctx.tiff.id})
               )
    end

    test "covering resident from another schedule", ctx do
      {:ok, other_schedule} = ResidencySchedule.Schedules.upsert_schedule(2025, "2025–2026")

      {:ok, outsider} =
        ResidencySchedule.Residents.insert_resident(other_schedule.id, %{
          position_code: "R1-1",
          residency_year: 1,
          schedule_number: 1,
          name: "Zed"
        })

      assert {:error, :different_schedules} =
               ChangeRequests.request_coverage(
                 ctx.admin,
                 attrs(ctx, %{covering_schedule_resident_id: outsider.id})
               )
    end

    test "dates outside the rotation", ctx do
      assert {:error, :dates_outside_rotation} =
               ChangeRequests.request_coverage(ctx.admin, attrs(ctx, %{end_date: ~D[2026-07-25]}))

      assert {:error, :dates_outside_rotation} =
               ChangeRequests.request_coverage(
                 ctx.admin,
                 attrs(ctx, %{start_date: ~D[2026-07-10]})
               )

      assert {:error, :dates_outside_rotation} =
               ChangeRequests.request_coverage(
                 ctx.admin,
                 attrs(ctx, %{start_date: ~D[2026-07-17], end_date: ~D[2026-07-16]})
               )

      assert {:error, :dates_outside_rotation} =
               ChangeRequests.request_coverage(ctx.admin, attrs(ctx, %{start_date: nil}))
    end

    test "rotation already covered on those days", ctx do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: ctx.tiff_ob.id,
          covering_schedule_resident_id: ctx.mary.id,
          override_start_date: ~D[2026-07-16],
          override_end_date: ~D[2026-07-16]
        })

      assert {:error, :already_covered} = ChangeRequests.request_coverage(ctx.admin, attrs(ctx))
    end

    test "covering resident already covering elsewhere", ctx do
      mary_ob = rotation_on(ctx.mary, ~D[2026-07-15])

      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: mary_ob.id,
          covering_schedule_resident_id: ctx.clare.id,
          override_start_date: ~D[2026-07-16],
          override_end_date: ~D[2026-07-16]
        })

      assert {:error, :covering_resident_busy} =
               ChangeRequests.request_coverage(ctx.admin, attrs(ctx))
    end

    test "duplicate pending request on overlapping days", ctx do
      assert {:ok, _} = ChangeRequests.request_coverage(ctx.admin, attrs(ctx))

      assert {:error, :duplicate_request} =
               ChangeRequests.request_coverage(
                 ctx.admin,
                 attrs(ctx, %{start_date: ~D[2026-07-16], end_date: ~D[2026-07-17]})
               )
    end
  end

  describe "approve_request/3" do
    test "creates the override and marks approved", ctx do
      {:ok, request} = ChangeRequests.request_coverage(ctx.clare_user, attrs(ctx))
      assert {:ok, approved} = ChangeRequests.approve_request(ctx.admin, request.id, "ok")
      assert approved.status == :approved
      assert approved.review_note == "ok"
      assert approved.reviewed_by_user.id == ctx.admin.id
      assert approved.shift_override_id

      assert ShiftOverrides.rotation_covered_in_range?(
               ctx.tiff_ob.id,
               ~D[2026-07-15],
               ~D[2026-07-15]
             )

      segs = Rotations.effective_segments_for_resident(ctx.clare.id)
      assert Enum.any?(segs, &(&1.is_coverage and &1.rotation_type == "strong_obstetrics"))
    end

    test "non-admin is forbidden", ctx do
      {:ok, request} = ChangeRequests.request_coverage(ctx.clare_user, attrs(ctx))
      assert {:error, :forbidden} = ChangeRequests.approve_request(ctx.clare_user, request.id)
    end

    test "unknown or non-pending request", ctx do
      assert {:error, :not_found} = ChangeRequests.approve_request(ctx.admin, 0)
      {:ok, request} = ChangeRequests.request_coverage(ctx.clare_user, attrs(ctx))
      {:ok, _} = ChangeRequests.deny_request(ctx.admin, request.id)
      assert {:error, :not_pending} = ChangeRequests.approve_request(ctx.admin, request.id)
    end

    test "rolls back when the override cannot be created", ctx do
      {:ok, request} = ChangeRequests.request_coverage(ctx.clare_user, attrs(ctx))
      Repo.delete_all(from(r in Rotations.Rotation, where: r.id == ^ctx.tiff_ob.id))
      assert {:error, :not_found} = ChangeRequests.approve_request(ctx.admin, request.id)
      assert Repo.aggregate(ChangeRequest, :count) == 0
    end
  end

  describe "deny_request/3" do
    test "marks denied without an override", ctx do
      {:ok, request} = ChangeRequests.request_coverage(ctx.clare_user, attrs(ctx))
      assert {:ok, denied} = ChangeRequests.deny_request(ctx.admin, request.id, "no")
      assert denied.status == :denied
      assert denied.review_note == "no"

      refute ShiftOverrides.rotation_covered_in_range?(
               ctx.tiff_ob.id,
               ~D[2026-07-15],
               ~D[2026-07-16]
             )
    end

    test "non-admin is forbidden", ctx do
      {:ok, request} = ChangeRequests.request_coverage(ctx.clare_user, attrs(ctx))
      assert {:error, :forbidden} = ChangeRequests.deny_request(ctx.tiff_user, request.id)
    end
  end

  describe "cancel_request/2" do
    test "requester may cancel", ctx do
      {:ok, request} = ChangeRequests.request_coverage(ctx.clare_user, attrs(ctx))

      assert {:ok, %{status: :cancelled}} =
               ChangeRequests.cancel_request(ctx.clare_user, request.id)
    end

    test "admin may cancel", ctx do
      {:ok, request} = ChangeRequests.request_coverage(ctx.clare_user, attrs(ctx))
      assert {:ok, %{status: :cancelled}} = ChangeRequests.cancel_request(ctx.admin, request.id)
    end

    test "other party may not cancel", ctx do
      {:ok, request} = ChangeRequests.request_coverage(ctx.clare_user, attrs(ctx))
      assert {:error, :forbidden} = ChangeRequests.cancel_request(ctx.tiff_user, request.id)
    end

    test "cannot cancel a reviewed request", ctx do
      {:ok, request} = ChangeRequests.request_coverage(ctx.clare_user, attrs(ctx))
      {:ok, _} = ChangeRequests.approve_request(ctx.admin, request.id)
      assert {:error, :not_pending} = ChangeRequests.cancel_request(ctx.clare_user, request.id)
      assert {:error, :not_found} = ChangeRequests.cancel_request(ctx.clare_user, 0)
    end
  end

  describe "list_requests/2 and get_request/1" do
    test "admin sees everything; parties see their own; strangers see nothing", ctx do
      {:ok, request} = ChangeRequests.request_coverage(ctx.clare_user, attrs(ctx))

      assert [%{id: id}] = ChangeRequests.list_requests(ctx.admin)
      assert id == request.id
      assert [_] = ChangeRequests.list_requests(ctx.clare_user)
      assert [_] = ChangeRequests.list_requests(ctx.tiff_user)
      assert [] = ChangeRequests.list_requests(ctx.mary_user)
      assert [] = ChangeRequests.list_requests(ctx.stranger)
    end

    test "requester without a home resident still sees their request", ctx do
      {:ok, request} = ChangeRequests.request_coverage(ctx.admin, attrs(ctx))
      {:ok, unlinked_clare} = ResidencySchedule.Accounts.clear_home_resident(ctx.clare_user)
      assert [] = ChangeRequests.list_requests(unlinked_clare)
      assert [_] = ChangeRequests.list_requests(ctx.admin)
      assert ChangeRequests.get_request(request.id).id == request.id
      assert ChangeRequests.get_request(0) == nil
    end

    test "filters by status", ctx do
      {:ok, request} = ChangeRequests.request_coverage(ctx.clare_user, attrs(ctx))
      {:ok, _} = ChangeRequests.deny_request(ctx.admin, request.id)
      assert [] = ChangeRequests.list_requests(ctx.admin, :pending)
      assert [_] = ChangeRequests.list_requests(ctx.admin, :denied)
    end
  end
end
