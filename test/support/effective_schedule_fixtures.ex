defmodule ResidencySchedule.EffectiveScheduleFixtures do
  @moduledoc """
  Synthetic schedules for the Phase 3 comparison harness, one per scenario of
  the release plan's comparison and acceptance contract. Each function seeds
  the database and returns a context map with the schedule, the schedule
  residents involved and the dates the scenario's assertions refer to.

  Every fixture uses synthetic residents (Ada, Bea, Cal, Dee) only. These
  functions hit the database, so they are exempt from doctests; see
  `ResidencySchedule.EffectiveSchedule.AcceptanceTest`.
  """

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.Importer.ScheduleImporter

  alias ResidencySchedule.{
    Repo,
    Residents,
    Rotations,
    ScheduleFixtures,
    Schedules,
    ShiftOverrides
  }

  @contact_night "SMH Obstetrics Resident 1st Contact Night"
  @second_contact_night "SMH Obstetrics Resident 2nd Contact Night"
  @highland_night "HH Nights 2nd Call"
  @highland_extra_night "HH Nights 3rd Call"

  @doc """
  April 5–18, 2027 vacation for Ada assembled from two roster weekday slots
  (`vacation` Mon–Fri) and imported weekend `"Vacation"` activities whose
  sources carry dated notes. Ada works ambulatory the week before and oncology
  the week after; Bea is on oncology across the whole range.

  Returns the schedule, `ada`, `bea`, the vacation range, and its weekend and
  weekday dates. Exempt from doctest — hits the database.
  """
  def april_vacation do
    schedule = schedule_2026()
    ada = resident(schedule, "Ada", 1)
    bea = resident(schedule, "Bea", 2)

    insert_blocks(ada, [
      {:ambulatory, ~D[2027-03-29], ~D[2027-04-04]},
      {:vacation, ~D[2027-04-05], ~D[2027-04-09]},
      {:vacation, ~D[2027-04-12], ~D[2027-04-16]},
      {:oncology, ~D[2027-04-19], ~D[2027-04-25]}
    ])

    insert_blocks(bea, [{:oncology, ~D[2027-03-29], ~D[2027-04-25]}])

    weekends = [~D[2027-04-10], ~D[2027-04-11], ~D[2027-04-17], ~D[2027-04-18]]

    for date <- weekends do
      add_activity(ada, date, "Vacation", notes: [dated_note(date, "vacation approved by chief")])
    end

    %{
      schedule: schedule,
      ada: ada,
      bea: bea,
      vacation_range: Date.range(~D[2027-04-05], ~D[2027-04-18]),
      weekends: weekends,
      weekdays:
        Enum.to_list(Date.range(~D[2027-04-05], ~D[2027-04-09])) ++
          Enum.to_list(Date.range(~D[2027-04-12], ~D[2027-04-16]))
    }
  end

  @doc """
  Ada on Strong obstetrics April 5–11, 2027 with an imported clinic activity on
  April 7. Bea is on ambulatory across the same week.

  Returns the schedule, `ada`, `bea`, the clinic date and task. Exempt from
  doctest — hits the database.
  """
  def rotation_and_clinic_same_day do
    schedule = schedule_2026()
    ada = resident(schedule, "Ada", 1)
    bea = resident(schedule, "Bea", 2)

    insert_blocks(ada, [{:strong_obstetrics, ~D[2027-04-05], ~D[2027-04-11]}])
    insert_blocks(bea, [{:ambulatory, ~D[2027-04-05], ~D[2027-04-11]}])
    add_activity(ada, ~D[2027-04-07], "Continuity Clinic AM")

    %{
      schedule: schedule,
      ada: ada,
      bea: bea,
      clinic_date: ~D[2027-04-07],
      clinic_task: "Continuity Clinic AM"
    }
  end

  @doc """
  Gap filling and approved coverage precedence, April 5–18, 2027.

  Ada: ambulatory Apr 5–9, a blank weekend with an imported `"Ultrasound"`
  gap fill on Saturday Apr 10, elective Apr 12–18. Bea: Strong obstetrics all
  range, covered by Cal on Apr 14–15. Cal: oncology Apr 5–11 and nothing after,
  with `"Ultrasound"` activities on Apr 14 (inside the covered range) and on
  Apr 16 (outside it).

  Returns the schedule, the residents, the gap-fill, coverage and contrast
  dates. Exempt from doctest — hits the database.
  """
  def gap_fill_and_coverage do
    schedule = schedule_2026()
    ada = resident(schedule, "Ada", 1)
    bea = resident(schedule, "Bea", 2)
    cal = resident(schedule, "Cal", 3)

    insert_blocks(ada, [
      {:ambulatory, ~D[2027-04-05], ~D[2027-04-09]},
      {:elective, ~D[2027-04-12], ~D[2027-04-18]}
    ])

    insert_blocks(bea, [{:strong_obstetrics, ~D[2027-04-05], ~D[2027-04-18]}])
    insert_blocks(cal, [{:oncology, ~D[2027-04-05], ~D[2027-04-11]}])

    add_activity(ada, ~D[2027-04-10], "Ultrasound")
    add_activity(cal, ~D[2027-04-14], "Ultrasound")
    add_activity(cal, ~D[2027-04-16], "Ultrasound")

    covered = Rotations.get_rotation_for_resident_on_date(bea.id, ~D[2027-04-14])

    {:ok, override} =
      ShiftOverrides.create_override(%{
        rotation_id: covered.id,
        covering_schedule_resident_id: cal.id,
        override_start_date: ~D[2027-04-14],
        override_end_date: ~D[2027-04-15]
      })

    %{
      schedule: schedule,
      ada: ada,
      bea: bea,
      cal: cal,
      override: override,
      gap_fill_date: ~D[2027-04-10],
      blank_date: ~D[2027-04-11],
      coverage_dates: [~D[2027-04-14], ~D[2027-04-15]],
      covered_gap_date: ~D[2027-04-14],
      uncovered_gap_date: ~D[2027-04-16]
    }
  end

  @doc """
  Strong and Highland overnight boundaries plus the Friday correction, built
  on the canonical November 2026 slots.

  Ada: ambulatory Nov 2–6, Strong weekend nights Nov 7–8, ambulatory Nov 9–13.
  Bea: night float Nov 2–6, post call Nov 7–8, night float Nov 9–13, with a
  literal Friday Nov 6 contact-night activity for both Ada and Bea. Cal:
  ambulatory Nov 9–13 with a literal Friday Nov 13 contact night. Dee: post
  call Nov 7–8 overlapping Highland night float Nov 8–13 with imported Highland
  night activities, a Saturday Nov 14 and a Sunday Nov 15 Highland night with
  no rotation.

  Returns the schedule, residents and the dates named above. Exempt from
  doctest — hits the database.
  """
  def night_boundaries_and_friday do
    schedule = schedule_2026()
    ada = resident(schedule, "Ada", 1)
    bea = resident(schedule, "Bea", 2)
    cal = resident(schedule, "Cal", 3)
    dee = resident(schedule, "Dee", 4)

    insert_blocks(ada, [
      {:ambulatory, ~D[2026-11-02], ~D[2026-11-06]},
      {:strong_weekend_nights, ~D[2026-11-07], ~D[2026-11-08]},
      {:ambulatory, ~D[2026-11-09], ~D[2026-11-13]}
    ])

    insert_blocks(bea, [
      {:night_float, ~D[2026-11-02], ~D[2026-11-06]},
      {:post_call, ~D[2026-11-07], ~D[2026-11-08]},
      {:night_float, ~D[2026-11-09], ~D[2026-11-13]}
    ])

    insert_blocks(cal, [{:ambulatory, ~D[2026-11-09], ~D[2026-11-13]}])

    insert_blocks(dee, [
      {:post_call, ~D[2026-11-07], ~D[2026-11-08]},
      {:highland_night_float, ~D[2026-11-08], ~D[2026-11-13]}
    ])

    add_activity(ada, ~D[2026-11-06], @contact_night)
    add_activity(bea, ~D[2026-11-06], @contact_night)
    add_activity(cal, ~D[2026-11-13], @second_contact_night)

    for date <- Date.range(~D[2026-11-08], ~D[2026-11-12]) do
      add_activity(dee, date, @highland_night)
    end

    add_activity(dee, ~D[2026-11-14], @highland_extra_night)
    add_activity(dee, ~D[2026-11-15], @highland_extra_night)

    %{
      schedule: schedule,
      ada: ada,
      bea: bea,
      cal: cal,
      dee: dee,
      explicit_friday: ~D[2026-11-06],
      corrected_friday: ~D[2026-11-13],
      shifted_sunday: ~D[2026-11-01],
      highland_saturday: ~D[2026-11-14],
      highland_sunday: ~D[2026-11-15]
    }
  end

  @doc """
  Blank days, an explicit `"OFF"` task, an unknown task and the same task under
  a changed label, April 5–25, 2027.

  Ada: ambulatory Apr 5–11, no rotation Apr 12–18, oncology Apr 19–25, with
  activities `"OFF"` on Apr 13, `"Mystery Clinic PM"` on Apr 14 and
  `"Mystery Clinic - PM"` on Apr 15. Bea is on ambulatory across the range.

  Returns the schedule, residents, the task labels and dates. Exempt from
  doctest — hits the database.
  """
  def blank_off_unknown_and_changed_labels do
    schedule = schedule_2026()
    ada = resident(schedule, "Ada", 1)
    bea = resident(schedule, "Bea", 2)

    insert_blocks(ada, [
      {:ambulatory, ~D[2027-04-05], ~D[2027-04-11]},
      {:oncology, ~D[2027-04-19], ~D[2027-04-25]}
    ])

    insert_blocks(bea, [{:ambulatory, ~D[2027-04-05], ~D[2027-04-25]}])

    add_activity(ada, ~D[2027-04-13], "OFF")
    add_activity(ada, ~D[2027-04-14], "Mystery Clinic PM")
    add_activity(ada, ~D[2027-04-15], "Mystery Clinic - PM")

    %{
      schedule: schedule,
      ada: ada,
      bea: bea,
      blank_dates: [~D[2027-04-12], ~D[2027-04-16], ~D[2027-04-17], ~D[2027-04-18]],
      off_date: ~D[2027-04-13],
      unknown_date: ~D[2027-04-14],
      unknown_task: "Mystery Clinic PM",
      changed_label_date: ~D[2027-04-15],
      changed_label_task: "Mystery Clinic - PM"
    }
  end

  @doc """
  Imports `test/fixtures/sample.csv` twice, then a corrected variant in which
  Briar's (`R4-1`) first July 2023 week is Strong gynecology instead of
  oncology.

  `snapshot` is called with the schedule id after each import so the caller
  can capture reads that a later import would replace.

  Returns the schedule id, the schedule ids and the schedule resident and
  person ids keyed by position code after each import (`:first`, `:second`,
  `:third`), the snapshots, the corrected position code, its corrected dates
  and the original and corrected rotation types. Exempt from doctest — hits
  the database.
  """
  def reimport_and_correction(snapshot \\ fn _schedule_id -> nil end) do
    csv = File.read!("test/fixtures/sample.csv")
    corrected = String.replace(csv, "R4-1,Briar,ONC,HWD,", "R4-1,Briar,GYN,HWD,")
    true = corrected != csv

    imports =
      for {key, binary} <- [first: csv, second: csv, third: corrected] do
        {:ok, result, _warnings} = ScheduleImporter.import_csv(binary)

        {key,
         %{
           schedule_id: result.schedule_id,
           ids: ids_by_position(result.schedule_id),
           snapshot: snapshot.(result.schedule_id)
         }}
      end

    %{
      schedule_id: imports[:third].schedule_id,
      schedule_ids: Enum.map(imports, fn {_key, import} -> import.schedule_id end),
      ids: Map.new(imports, fn {key, import} -> {key, import.ids} end),
      snapshots: Map.new(imports, fn {key, import} -> {key, import.snapshot} end),
      corrected_position: "R4-1",
      corrected_dates: Enum.to_list(Date.range(~D[2023-07-03], ~D[2023-07-07])),
      original_type: "oncology",
      corrected_type: "strong_gynecology"
    }
  end

  defp schedule_2026 do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")
    schedule
  end

  defp resident(schedule, name, number) do
    {:ok, resident} =
      Residents.insert_resident(schedule.id, %{
        name: name,
        position_code: "R2-#{number}",
        residency_year: 2,
        schedule_number: number
      })

    resident
  end

  defp insert_blocks(resident, blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.map(fn {{type, first, last}, index} ->
      %{rotation_type: type, start_date: first, end_date: last, slot_index: index}
    end)
    |> then(&Rotations.insert_rotations(resident.id, &1))
  end

  defp add_activity(resident, date, task, options \\ []) do
    admin = ScheduleFixtures.admin_user()

    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: resident.schedule_id,
        created_by_id: admin.id,
        fingerprint: Ecto.UUID.generate(),
        header_start: date,
        header_end: date
      })

    activity =
      Repo.insert!(%Activity{schedule_resident_id: resident.id, date: date, raw_task: task})

    Repo.insert!(%ActivitySource{
      activity_id: activity.id,
      batch_id: batch.id,
      source_sheet: "Synthetic",
      source_cell: "A#{activity.id}",
      raw_staff: resident.name,
      display_name: resident.name,
      previous_name: resident.name,
      notes: Keyword.get(options, :notes, [])
    })

    activity
  end

  defp dated_note(date, text) do
    %{
      "text" => "#{date.month}/#{date.day}/#{date.year} #{text}",
      "source_sheet" => "Synthetic",
      "source_cell" => "N#{date.day}"
    }
  end

  defp ids_by_position(schedule_id) do
    schedule_id
    |> Residents.list_residents_for_schedule()
    |> Map.new(&{&1.position_code, %{schedule_resident_id: &1.id, person_id: &1.resident_id}})
  end
end
