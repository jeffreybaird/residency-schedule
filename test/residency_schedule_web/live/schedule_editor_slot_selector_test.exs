defmodule ResidencyScheduleWeb.ScheduleEditorSlotSelectorTest do
  use ResidencyScheduleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.Rotations.Rotation

  setup :admin_authenticate_session

  setup do
    csv = ",Dates,2026-12-01\n,,2027-01-31\n,,Events\nR1-1,Original,FLOAT\nR1-2,Empty,OB\n"
    {:ok, summary, _} = ScheduleImporter.import_csv(csv)
    [first, empty] = Residents.list_residents_for_schedule(summary.schedule_id)
    original = hd(Residents.get_resident!(first.id).rotations)
    empty.id |> Residents.get_resident!() |> Map.fetch!(:rotations) |> Enum.each(&Repo.delete!/1)

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
      empty: empty,
      original: original,
      overlap: overlap
    }
  end

  test "empty slot opens an accessible selector with resident and every shift but no dates",
       context do
    view = load_editor(context)
    assert has_element?(view, slot(context.empty.id, 1) <> "[aria-label]")
    refute has_element?(view, "#editor-grid td[phx-click]")
    view |> element(slot(context.empty.id, 1)) |> render_click()

    assert has_element?(view, "#assignment-dialog[role='dialog'][aria-modal='true']")
    assert has_element?(view, "#assignment-dialog", context.empty.name)
    assert_no_dates(view)

    for type <- Rotations.all_rotation_types() do
      assert has_element?(
               view,
               "#assignment-form select[name='assignment[rotation_type]'] option[value='#{type}']"
             )
    end

    refute has_element?(view, "button[phx-click='undo']:not([disabled])")
    assert Residents.get_resident!(context.empty.id).rotations == []
  end

  test "applying a slot shift changes the draft and Save persists only that resident and dates",
       context do
    view = load_editor(context)
    view |> element(slot(context.empty.id, 1)) |> render_click()
    apply_shift(view, "strong_weekend_nights")

    refute has_element?(view, "#assignment-dialog")
    assert has_element?(view, "#editor-grid [data-rotation-id='new-1']", "SWN")
    assert Residents.get_resident!(context.empty.id).rotations == []
    assert Repo.get!(Rotation, context.original.id) == context.original
    assert Repo.get!(Rotation, context.overlap.id) == context.overlap

    view |> element("button[phx-click='save']") |> render_click()
    [saved] = Residents.get_resident!(context.empty.id).rotations
    assert saved.rotation_type == "strong_weekend_nights"
    assert saved.start_date == ~D[2026-12-14]
    assert saved.end_date == ~D[2026-12-18]
    assert Repo.get!(Rotation, context.original.id) == context.original
    assert Repo.get!(Rotation, context.overlap.id) == context.overlap
  end

  test "occupied single-assignment slot edits the whole assignment across columns", context do
    view = load_editor(context)
    view |> element(slot(context.first.id, 2)) |> render_click()
    assert_no_dates(view)
    assert has_element?(view, "#assignment-form option[value='float'][selected]")
    apply_shift(view, "post_call")
    assert Repo.get!(Rotation, context.original.id) == context.original
    view |> element("button[phx-click='save']") |> render_click()

    saved = Repo.get!(Rotation, context.original.id)
    assert saved.rotation_type == "post_call"
    assert saved.start_date == context.original.start_date
    assert saved.end_date == context.original.end_date
    assert saved.slot_index == context.original.slot_index
    assert Repo.get!(Rotation, context.overlap.id) == context.overlap
  end

  test "overlap slot asks which assignment to edit before allowing a draft update", context do
    view = load_editor(context)
    view |> element(slot(context.first.id, 1)) |> render_click()
    refute has_element?(view, "#assignment-form")
    assert_no_dates(view)

    for rotation <- [context.original, context.overlap] do
      assert has_element?(
               view,
               "#assignment-dialog [phx-click='choose_slot_assignment'][phx-value-id='#{rotation.id}']"
             )
    end

    assert has_element?(view, "#assignment-dialog [phx-click='add_slot_assignment']")

    view
    |> element(
      "#assignment-dialog [phx-click='choose_slot_assignment'][phx-value-id='#{context.overlap.id}']"
    )
    |> render_click()

    assert_no_dates(view)
    apply_shift(view, "ambulatory")
    view |> element("button[phx-click='save']") |> render_click()
    assert Repo.get!(Rotation, context.overlap.id).rotation_type == "ambulatory"
    assert Repo.get!(Rotation, context.original.id) == context.original
  end

  test "overlap selector can add a separate shift without replacing either assignment", context do
    view = load_editor(context)
    view |> element(slot(context.first.id, 1)) |> render_click()
    view |> element("#assignment-dialog [phx-click='add_slot_assignment']") |> render_click()
    assert_no_dates(view)
    apply_shift(view, "post_call")
    assert length(Residents.get_resident!(context.first.id).rotations) == 2
    view |> element("button[phx-click='save']") |> render_click()
    saved = Residents.get_resident!(context.first.id).rotations
    assert length(saved) == 3

    assert Enum.any?(
             saved,
             &(&1.rotation_type == "post_call" and &1.start_date == ~D[2026-12-14] and
                 &1.end_date == ~D[2026-12-18])
           )

    assert Repo.get!(Rotation, context.original.id) == context.original
    assert Repo.get!(Rotation, context.overlap.id) == context.overlap
  end

  test "cancel closes both slot forms and overlap choices without creating undo history",
       context do
    view = load_editor(context)
    before = snapshot(context.schedule_id)

    for resident <- [context.empty, context.first] do
      view |> element(slot(resident.id, 1)) |> render_click()
      view |> element("#assignment-dialog button[phx-click='close_assignment']") |> render_click()
      refute has_element?(view, "#assignment-dialog")
      refute has_element?(view, "button[phx-click='undo']:not([disabled])")
    end

    view |> element("button[phx-click='save']") |> render_click()
    assert snapshot(context.schedule_id) == before
  end

  test "undo discards a shift staged through the slot selector", context do
    view = load_editor(context)
    view |> element(slot(context.empty.id, 1)) |> render_click()
    apply_shift(view, "post_call")
    view |> element("button[phx-click='undo']") |> render_click()
    refute has_element?(view, "#editor-grid [data-rotation-id='new-1']")
    view |> element("button[phx-click='save']") |> render_click()
    assert Residents.get_resident!(context.empty.id).rotations == []
  end

  test "badge and delete controls remain independent from the slot hit area", context do
    view = load_editor(context)

    view
    |> element("#editor-grid [phx-click='edit_assignment'][phx-value-id='#{context.overlap.id}']")
    |> render_click()

    assert_dates(view, "2026-12-14", "2026-12-18")
    view |> element("#assignment-dialog button[phx-click='close_assignment']") |> render_click()

    view
    |> element(
      "#editor-grid [phx-click='delete_assignment'][phx-value-id='#{context.overlap.id}']"
    )
    |> render_click()

    refute has_element?(view, "#assignment-dialog")
    assert Repo.get!(Rotation, context.overlap.id) == context.overlap
    view |> element("button[phx-click='save']") |> render_click()
    assert Repo.get(Rotation, context.overlap.id) == nil
    assert Repo.get!(Rotation, context.original.id) == context.original
  end

  test "malformed and foreign slot events cannot open a selector or change records", context do
    foreign_csv = ",Dates,2025-12-01\n,,2026-01-31\n,,Events\nR1-1,Foreign,FLOAT\n"
    {:ok, foreign, _} = ScheduleImporter.import_csv(foreign_csv)
    [foreign_resident] = Residents.list_residents_for_schedule(foreign.schedule_id)
    view = load_editor(context)
    before = snapshot(context.schedule_id)
    foreign_before = snapshot(foreign.schedule_id)

    for id <- ["bad", "-1", %{}, to_string(foreign_resident.id)] do
      render_click(view, "choose_slot_assignment", %{"id" => id})
      refute has_element?(view, "#assignment-dialog")
    end

    invalid = [
      %{},
      %{"resident-id" => to_string(context.empty.id)},
      %{"resident-id" => "bad", "slot-index" => "1"},
      %{"resident-id" => "-1", "slot-index" => "1"},
      %{"resident-id" => to_string(foreign_resident.id), "slot-index" => "1"},
      %{"resident-id" => to_string(context.empty.id), "slot-index" => "-1"},
      %{"resident-id" => to_string(context.empty.id), "slot-index" => "999"},
      %{"resident-id" => to_string(context.empty.id), "slot-index" => "1junk"},
      %{"resident-id" => to_string(context.empty.id), "slot-index" => %{}},
      %{"resident-id" => [], "slot-index" => "1"}
    ]

    for event <- ["select_slot", "add_slot_assignment"], params <- invalid do
      render_click(view, event, params)
      refute has_element?(view, "#assignment-dialog")
    end

    view |> element("button[phx-click='save']") |> render_click()
    assert snapshot(context.schedule_id) == before
    assert snapshot(foreign.schedule_id) == foreign_before
    view |> element(slot(context.empty.id, 1)) |> render_click()
    assert_no_dates(view)
  end

  test "overlap choice rejects an assignment outside the selected slot", context do
    other =
      Repo.insert!(%Rotation{
        schedule_resident_id: context.empty.id,
        slot_index: 131,
        rotation_type: "oncology",
        start_date: ~D[2026-12-14],
        end_date: ~D[2026-12-18]
      })

    view = load_editor(context)
    view |> element(slot(context.first.id, 1)) |> render_click()

    for params <- [%{}, %{"id" => "bad"}, %{"id" => to_string(other.id)}] do
      render_click(view, "choose_slot_assignment", params)
      refute has_element?(view, "#assignment-form")
    end

    view
    |> element(
      "#assignment-dialog [phx-click='choose_slot_assignment'][phx-value-id='#{context.overlap.id}']"
    )
    |> render_click()

    apply_shift(view, "post_call")
    view |> element("button[phx-click='save']") |> render_click()
    assert Repo.get!(Rotation, context.overlap.id).rotation_type == "post_call"
    assert Repo.get!(Rotation, other.id) == other
    assert Repo.get!(Rotation, context.original.id) == context.original
  end

  test "cell shift submission cannot override internally selected dates", context do
    view = load_editor(context)

    for resident <- [context.empty, context.first] do
      view |> element(slot(resident.id, 2)) |> render_click()

      render_submit(view, "stage_assignment", %{
        "assignment" => %{
          "rotation_type" => "post_call",
          "start_date" => "2026-12-25",
          "end_date" => "2026-12-25"
        }
      })
    end

    view |> element("button[phx-click='save']") |> render_click()
    [added] = Residents.get_resident!(context.empty.id).rotations
    assert added.rotation_type == "post_call"
    assert added.start_date == ~D[2026-12-19]
    assert added.end_date == ~D[2027-01-31]
    updated = Repo.get!(Rotation, context.original.id)
    assert updated.rotation_type == "post_call"
    assert updated.start_date == context.original.start_date
    assert updated.end_date == context.original.end_date
    assert Repo.get!(Rotation, context.overlap.id) == context.overlap
  end

  test "slot dialogs move and trap keyboard focus, then restore the triggering control",
       context do
    view = load_editor(context)

    for resident <- [context.empty, context.first] do
      view |> element(slot(resident.id, 1)) |> render_click()

      assert has_element?(
               view,
               "#assignment-focus-wrap[phx-hook='Phoenix.FocusWrap'] #assignment-dialog"
             )

      assert has_element?(
               view,
               "#assignment-dialog[phx-window-keydown='close_assignment'][phx-key='Escape']"
             )

      assert ["push_focus", %{"to" => "#select-slot-#{resident.id}-1"}] in js_commands(
               view,
               "#assignment-dialog",
               "phx-mounted"
             )

      assert ["focus_first", %{"to" => "#assignment-dialog"}] in js_commands(
               view,
               "#assignment-dialog",
               "phx-mounted"
             )

      assert ["pop_focus", %{}] in js_commands(view, "#assignment-backdrop", "phx-remove")
      view |> element("#assignment-dialog button[phx-click='close_assignment']") |> render_click()
    end

    view |> element(slot(context.first.id, 1)) |> render_click()

    view
    |> element(
      "#assignment-dialog [phx-click='choose_slot_assignment'][phx-value-id='#{context.overlap.id}']"
    )
    |> render_click()

    assert ["focus_first", %{"to" => "#assignment-form"}] in js_commands(
             view,
             "#assignment-form",
             "phx-mounted"
           )

    assert_no_dates(view)
  end

  defp js_commands(view, selector, attribute) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
    |> List.first()
    |> Jason.decode!()
  end

  defp slot(resident_id, index),
    do:
      "#editor-grid button[phx-click='select_slot'][phx-value-resident-id='#{resident_id}'][phx-value-slot-index='#{index}']"

  defp load_editor(context) do
    {:ok, view, _} = live(context.conn, "/admin/edit")

    view
    |> form("#load-editor-form", %{"schedule_id" => to_string(context.schedule_id)})
    |> render_submit()

    view
  end

  defp assert_dates(view, first, last) do
    assert has_element?(
             view,
             "#assignment-form input[name='assignment[start_date]'][value='#{first}']"
           )

    assert has_element?(
             view,
             "#assignment-form input[name='assignment[end_date]'][value='#{last}']"
           )
  end

  defp assert_no_dates(view) do
    refute has_element?(view, "#assignment-dialog input[name='assignment[start_date]']")
    refute has_element?(view, "#assignment-dialog input[name='assignment[end_date]']")
    refute has_element?(view, "#assignment-dialog input[type='date']")
    refute has_element?(view, "#assignment-dialog", "2026-12")
    refute has_element?(view, "#assignment-dialog", "2027-01")
    refute has_element?(view, "#assignment-dialog", "Dec")
    refute has_element?(view, "#assignment-dialog", "Jan")
  end

  defp apply_shift(view, type) do
    view
    |> form("#assignment-form", %{"assignment" => %{"rotation_type" => type}})
    |> render_submit()
  end

  defp snapshot(id),
    do: Residents.list_residents_for_schedule(id) |> Enum.map(&Residents.get_resident!(&1.id))
end
