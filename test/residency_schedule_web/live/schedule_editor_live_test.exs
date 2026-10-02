defmodule ResidencyScheduleWeb.ScheduleEditorLiveTest do
  use ResidencyScheduleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations.Rotation

  setup :admin_authenticate_session

  setup do
    csv = ",Dates,2026-12-01\n,,2027-01-31\n,,Events\nR1-1,Original,FLOAT\nR1-2,Other,OB\n"
    {:ok, summary, _} = ScheduleImporter.import_csv(csv)
    [first, second] = Residents.list_residents_for_schedule(summary.schedule_id)
    original = hd(Residents.get_resident!(first.id).rotations)

    overlap =
      Repo.insert!(%Rotation{
        schedule_resident_id: first.id,
        slot_index: 131,
        rotation_type: "highland_night_float",
        start_date: ~D[2026-12-14],
        end_date: ~D[2026-12-18]
      })

    %{
      schedule_id: summary.schedule_id,
      first: first,
      second: second,
      original: original,
      overlap: overlap
    }
  end

  test "loads actual date ranges and both overlapping assignments", context do
    view = load_editor(context)

    assert has_element?(
             view,
             "#editor-grid [data-rotation-id='#{context.original.id}'][data-start-date='2026-12-01'][data-end-date='2027-01-31']",
             "FLOAT"
           )

    assert has_element?(
             view,
             "#editor-grid [data-rotation-id='#{context.overlap.id}'][data-start-date='2026-12-14'][data-end-date='2026-12-18']",
             "HNF"
           )

    refute has_element?(view, "input[phx-blur='rename_resident']")
    before = snapshot(context.schedule_id)
    view |> element("button[phx-click='save']") |> render_click()
    assert snapshot(context.schedule_id) == before
  end

  test "stages a selected overlap edit until Save and refreshes its baseline", context do
    view = load_editor(context)
    edit(view, context.overlap.id, "ambulatory")
    assert Repo.get!(Rotation, context.overlap.id) == context.overlap
    view |> element("button[phx-click='save']") |> render_click()
    assert Repo.get!(Rotation, context.overlap.id).rotation_type == "ambulatory"
    assert Repo.get!(Rotation, context.original.id) == context.original
    edit(view, context.overlap.id, "oncology")
    view |> element("button[phx-click='save']") |> render_click()
    assert Repo.get!(Rotation, context.overlap.id).rotation_type == "oncology"
    assert Repo.get!(Rotation, context.overlap.id).slot_index == 131
  end

  test "undo and cancel discard staged changes without touching database", context do
    view = load_editor(context)
    before = snapshot(context.schedule_id)
    edit(view, context.overlap.id, "ambulatory")
    view |> element("button[phx-click='undo']") |> render_click()
    view |> element("button[phx-click='save']") |> render_click()
    assert snapshot(context.schedule_id) == before
    edit(view, context.overlap.id, "oncology")
    view |> element("button[phx-click='cancel_edits']") |> render_click()
    view |> element("button[phx-click='save']") |> render_click()
    assert snapshot(context.schedule_id) == before
  end

  test "delete removes only selected overlapping assignment after Save", context do
    view = load_editor(context)

    view
    |> element("[phx-click='delete_assignment'][phx-value-id='#{context.overlap.id}']")
    |> render_click()

    assert Repo.get!(Rotation, context.overlap.id) == context.overlap
    view |> element("button[phx-click='save']") |> render_click()
    assert Repo.get(Rotation, context.overlap.id) == nil
    assert Repo.get!(Rotation, context.original.id) == context.original
  end

  test "add stages a separate assignment without replacing overlapping rotation", context do
    view = load_editor(context)

    view
    |> element("[phx-click='add_assignment'][phx-value-resident-id='#{context.first.id}']")
    |> render_click()

    view
    |> form("#assignment-form", %{
      "assignment" => %{
        "rotation_type" => "post_call",
        "start_date" => "2026-12-15",
        "end_date" => "2026-12-15"
      }
    })
    |> render_submit()

    assert length(Residents.get_resident!(context.first.id).rotations) == 2
    view |> element("button[phx-click='save']") |> render_click()
    saved = Residents.get_resident!(context.first.id)
    assert length(saved.rotations) == 3
    assert Repo.get!(Rotation, context.overlap.id) == context.overlap
    assert Repo.get!(Rotation, context.original.id) == context.original
  end

  test "tampered editor events and invalid form cannot crash or mutate records", context do
    view = load_editor(context)
    before = snapshot(context.schedule_id)

    for id <- ["invalid", "-1"] do
      render_click(view, "edit_assignment", %{"id" => id})
      render_click(view, "delete_assignment", %{"id" => id})
      render_click(view, "add_assignment", %{"resident-id" => id})
    end

    view
    |> element("[phx-click='edit_assignment'][phx-value-id='#{context.overlap.id}']")
    |> render_click()

    render_submit(view, "stage_assignment", %{
      "assignment" => %{
        "rotation_type" => "invalid",
        "start_date" => "not-a-date",
        "end_date" => "2026-12-18"
      }
    })

    view |> element("button[phx-click='save']") |> render_click()
    assert snapshot(context.schedule_id) == before
  end

  test "stale Save shows error and preserves concurrent change", context do
    view = load_editor(context)
    edit(view, context.overlap.id, "ambulatory")
    context.original |> Ecto.Changeset.change(rotation_type: "oncology") |> Repo.update!()
    before = snapshot(context.schedule_id)
    view |> element("button[phx-click='save']") |> render_click()
    assert has_element?(view, "#edit-save-error")
    assert snapshot(context.schedule_id) == before
  end

  test "resident cannot access editor" do
    %{conn: conn} = authenticate_session(%{conn: Phoenix.ConnTest.build_conn()})
    conn = get(conn, "/admin/edit")
    assert redirected_to(conn) == "/"
  end

  defp load_editor(context) do
    {:ok, view, _} = live(context.conn, "/admin/edit")

    view
    |> form("form[phx-submit='load_schedule']", %{"schedule_id" => to_string(context.schedule_id)})
    |> render_submit()

    view
  end

  defp edit(view, id, type) do
    view |> element("[phx-click='edit_assignment'][phx-value-id='#{id}']") |> render_click()

    view
    |> form("#assignment-form", %{
      "assignment" => %{
        "rotation_type" => type,
        "start_date" => "2026-12-14",
        "end_date" => "2026-12-18"
      }
    })
    |> render_submit()
  end

  defp snapshot(id),
    do: Residents.list_residents_for_schedule(id) |> Enum.map(&Residents.get_resident!(&1.id))
end
