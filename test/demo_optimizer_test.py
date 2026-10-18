"""Behavioral contract for the synthetic annual demo optimizer.

Run with python3 -m unittest discover -s test -p '*_test.py'.
These checks deliberately treat resident rotation equality as an objective.
"""

import copy
import csv
import hashlib
import importlib.util
import sys
import subprocess
import tempfile
import unittest
from collections import Counter
from datetime import date, timedelta
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "demo_optimizer", ROOT / "priv/demo/optimize_demo_schedule.py"
)
optimizer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = optimizer
SPEC.loader.exec_module(optimizer)
BASELINE = ROOT / "test/fixtures/demo_schedule_baseline.csv"
FIXTURE = ROOT / "priv/demo/demo_schedule.csv"


def slot(start, days, kind="weekday"):
    return {"column": 2, "start": start, "end": start + timedelta(days=days - 1), "kind": kind}


def loads(nights, weekend_shifts=None, weekends=None):
    weekend_shifts = weekend_shifts or [0] * len(nights)
    weekends = weekends or [0] * len(nights)
    return {
        f"R1-{index + 1}": {
            "night_shifts": night,
            "weekend_shifts": weekend_shifts[index],
            "weekends_worked": weekends[index],
        }
        for index, night in enumerate(nights)
    }


class ShiftProjectionTest(unittest.TestCase):
    def test_strong_nights_begin_sunday_and_highland_includes_friday(self):
        slots = [slot(date(2026, 7, 6), 5)]
        strong = optimizer.project_resident(slots, ["NF"])
        highland = optimizer.project_resident(slots, ["HNF"])
        self.assertEqual([row["date"] for row in strong["shifts"]],
                         [date(2026, 7, 5) + timedelta(days=n) for n in range(5)])
        self.assertEqual([row["date"] for row in highland["shifts"]],
                         [date(2026, 7, 5) + timedelta(days=n) for n in range(6)])
        self.assertEqual(optimizer.workload(strong)["night_shifts"], 5)
        self.assertEqual(optimizer.workload(highland)["night_shifts"], 6)
        self.assertEqual(optimizer.workload(highland)["weekend_shifts"], 2)
        self.assertEqual(optimizer.workload(highland)["weekends_worked"], 2)
        self.assertTrue(all(row["hours"] == 12 and row["night"] for row in highland["shifts"]))

    def test_ambulatory_weekend_nights_replace_friday_daytime(self):
        slots = [slot(date(2026, 7, 6), 5), slot(date(2026, 7, 11), 2, "weekend")]
        projected = optimizer.project_resident(slots, ["AMB", "SWN"])
        self.assertEqual([(row["date"], row["hours"], row["night"]) for row in projected["shifts"]],
                         [(date(2026, 7, 6) + timedelta(days=n), 8, False) for n in range(4)] +
                         [(date(2026, 7, 10), 12, True), (date(2026, 7, 11), 12, True)])
        self.assertEqual(optimizer.workload(projected),
                         {"night_shifts": 2, "weekend_shifts": 2, "weekends_worked": 1})

    def test_hospital_weekend_nights_are_saturday_only(self):
        projected = optimizer.project_resident([slot(date(2026, 7, 11), 2, "weekend")], ["HWN"])
        self.assertEqual([(row["date"], row["hours"]) for row in projected["shifts"]],
                         [(date(2026, 7, 11), 12)])

    def test_highland_importer_adjustments_also_apply_to_malformed_baseline_slots(self):
        weekend_night = optimizer.project_resident([slot(date(2026, 7, 6), 5)], ["HWN"])
        self.assertEqual([(row["date"], row["hours"]) for row in weekend_night["shifts"]],
                         [(date(2026, 7, 6), 12)])
        night_float = optimizer.project_resident([slot(date(2026, 7, 11), 2, "weekend")], ["HNF"])
        self.assertEqual([row["date"] for row in night_float["shifts"]],
                         [date(2026, 7, 10), date(2026, 7, 11), date(2026, 7, 12)])

    def test_weekends_are_distinct_calendar_weekends_including_friday_nights(self):
        projected = {"float_dates": set(), "shifts": [
            {"date": day, "hours": 12, "night": night, "rotation": "SWN" if night else "SWD"}
            for day, night in [(date(2026, 7, 10), True), (date(2026, 7, 11), True),
                               (date(2026, 7, 12), False), (date(2026, 7, 17), True)]]}
        self.assertEqual(optimizer.workload(projected),
                         {"night_shifts": 3, "weekend_shifts": 4, "weekends_worked": 2})

    def test_hospital_urogynecology_outpatient_and_zero_hour_labels(self):
        for label, hours in [("OB", 12), ("UG", 12), ("REI", 8), ("AMB", 8),
                             ("Vac", 0), ("P", 0), ("OFF", 0), ("", 0)]:
            with self.subTest(label=label):
                projected = optimizer.project_resident([slot(date(2026, 7, 6), 5)], [label])
                self.assertEqual(sum(row["hours"] for row in projected["shifts"]), 5 * hours)

    def test_unknown_rotations_fail_closed(self):
        with self.assertRaises(ValueError):
            optimizer.project_resident([slot(date(2026, 7, 6), 5)], ["NOT_A_ROTATION"])

    def test_rolling_daily_windows_count_weekends_and_mark_float_incomplete(self):
        start = date(2026, 7, 6)
        projected = {"float_dates": {start}, "shifts": [
            {"date": start + timedelta(days=n), "hours": 12, "night": False, "rotation": "OB"}
            for n in range(29)]}
        windows = optimizer.duty_windows(projected, start, start + timedelta(days=28))
        self.assertEqual(len(windows), 2)
        self.assertEqual([row["hours"] for row in windows], [336, 336])
        self.assertEqual([row["complete"] for row in windows], [False, True])
        self.assertEqual([row["start"] for row in windows], [start, start + timedelta(days=1)])

    def test_float_is_not_a_zero_hour_evaluated_rotation(self):
        start = date(2026, 12, 21)
        projected = optimizer.project_resident([slot(start, 7, "float")], ["FLOAT"])
        self.assertEqual(projected["shifts"], [])
        self.assertEqual(projected["float_dates"], {start + timedelta(days=n) for n in range(7)})


class FairnessPriorityTest(unittest.TestCase):
    def test_educational_targets_are_a_measured_soft_cost(self):
        education = {f"R1-{n}": {"HGYN": 6} for n in range(1, 9)}
        self.assertEqual(optimizer.education_target_deviation(education, {1: {"HGYN": 7}}), 8)
        self.assertEqual(optimizer.education_target_deviation(education, {1: {"HGYN": 6}}), 0)

    def test_exact_priority_vector_uses_scaled_class_mean_deviations(self):
        workload = loads([10, 12], [4, 6], [3, 3])
        education = {"R1-1": {"OB": 2, "NF": 1}, "R1-2": {"OB": 3, "NF": 1}}
        self.assertEqual(optimizer.fairness_objective(workload, education), (2, 4, 2, 0, 4, 0, 1, 2))

    def test_night_range_precedes_average_deviations_and_all_other_workload(self):
        fairer = loads([0, 0, 0, 0, 4, 4, 4, 4], [0, 100, 0, 100, 0, 100, 0, 100])
        worse = loads([0, 0, 0, 0, 0, 0, 0, 5])
        self.assertLess(optimizer.fairness_objective(fairer, {}),
                        optimizer.fairness_objective(worse, {}))

    def test_weekend_work_precedes_educational_rotation_equality(self):
        unequal_education = {"R1-1": {"OB": 1}, "R1-2": {"OB": 20}}
        equal_education = {"R1-1": {"OB": 8}, "R1-2": {"OB": 8}}
        self.assertLess(optimizer.fairness_objective(loads([10, 10], [6, 6], [3, 3]), unequal_education),
                        optimizer.fairness_objective(loads([10, 10], [4, 8], [3, 3]), equal_education))

    def test_fairness_compares_within_classes_not_between_classes(self):
        workload = {**loads([5, 5]), "R2-1": {"night_shifts": 30, "weekend_shifts": 0, "weekends_worked": 0}}
        self.assertEqual(optimizer.fairness_objective(workload, {}), (0,) * 8)


class VacationBlocksTest(unittest.TestCase):
    def test_two_single_weeks_and_one_double_week_are_accepted(self):
        slots = [slot(date(2026, 7, 6) + timedelta(weeks=n), 5) for n in range(8)]
        self.assertEqual(optimizer.vacation_run_lengths(slots,
                         ["VAC", "VAC", "OB", "VAC", "OB", "OB", "VAC", "OB"]), [2, 1, 1])

    def test_weekend_cells_do_not_split_adjacent_vacation_weeks(self):
        slots = [slot(date(2026, 7, 6), 5), slot(date(2026, 7, 11), 2, "weekend"),
                 slot(date(2026, 7, 13), 5)]
        self.assertEqual(optimizer.vacation_run_lengths(slots, ["VAC", "", "VAC"]), [2])

    def test_float_other_rotation_and_missing_calendar_week_break_runs(self):
        for slots, cells in [
            ([slot(date(2026, 7, 6), 5), slot(date(2026, 7, 13), 7, "float"),
              slot(date(2026, 7, 20), 5)], ["VAC", "FLOAT", "VAC"]),
            ([slot(date(2026, 7, 6), 5), slot(date(2026, 7, 13), 5),
              slot(date(2026, 7, 20), 5)], ["VAC", "OB", "VAC"]),
            ([slot(date(2026, 7, 6), 5), slot(date(2026, 7, 20), 5)], ["VAC", "VAC"]),
        ]:
            with self.subTest(cells=cells):
                self.assertEqual(optimizer.vacation_run_lengths(slots, cells), [1, 1])

    def test_validator_rejects_other_four_week_vacation_shapes(self):
        baseline = optimizer.load_schedule(BASELINE)
        for weeks, expected in [([0, 2, 4, 6], [1, 1, 1, 1]),
                                ([0, 1, 4, 5], [2, 2]),
                                ([0, 1, 2, 5], [3, 1]),
                                ([0, 1, 2, 3], [4])]:
            with self.subTest(weeks=weeks):
                candidate = self.with_vacation_weeks(baseline, weeks)
                self.assertEqual(optimizer.vacation_run_lengths(candidate.slots, candidate.grid["R1-1"]), expected)
                self.assertTrue(any(error["constraint"] == "vacation_blocks" and error.get("code") == "R1-1"
                                    for error in optimizer.validate_schedule(candidate, baseline)))

    def test_validator_accepts_required_shape_and_rejects_work_on_internal_weekend(self):
        baseline = optimizer.load_schedule(BASELINE)
        candidate = self.with_vacation_weeks(baseline, [0, 1, 4, 7])
        weekend_index = next(n for n, entry in enumerate(candidate.slots) if entry["kind"] == "weekend")
        candidate.grid["R1-1"][weekend_index] = ""
        errors = optimizer.validate_schedule(candidate, baseline)
        self.assertFalse(any(error["constraint"] in {"vacation_blocks", "protected_vacation_weekend"}
                             and error.get("code") == "R1-1" for error in errors))
        for label in ["SWD", "SWN", "HWD", "HWN", "AMB", "UG"]:
            with self.subTest(label=label):
                candidate.grid["R1-1"][weekend_index] = label
                self.assertTrue(any(error["constraint"] == "protected_vacation_weekend"
                                    and error.get("code") == "R1-1"
                                    for error in optimizer.validate_schedule(candidate, baseline)))

    def test_vacation_rule_does_not_add_protection_to_outer_weekends(self):
        baseline = optimizer.load_schedule(BASELINE)
        candidate = self.with_vacation_weeks(baseline, [0, 1, 4, 7])
        weekend_indices = [n for n, entry in enumerate(candidate.slots) if entry["kind"] == "weekend"]
        candidate.grid["R1-1"][weekend_indices[0]] = ""
        candidate.grid["R1-1"][weekend_indices[1]] = "SWD"
        self.assertFalse(any(error["constraint"] == "protected_vacation_weekend"
                             and error.get("code") == "R1-1"
                             for error in optimizer.validate_schedule(candidate, baseline)))

    @staticmethod
    def with_vacation_weeks(baseline, weeks):
        candidate = copy.deepcopy(baseline)
        cells = candidate.grid["R1-1"]
        for index, label in enumerate(cells):
            if label == "VAC":
                cells[index] = "HGYN"
        weekday_indices = [n for n, entry in enumerate(candidate.slots) if entry["kind"] == "weekday"]
        for week in weeks:
            cells[weekday_indices[week]] = "VAC"
        return candidate


class AnnualFixtureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.baseline = optimizer.load_schedule(BASELINE)
        cls.schedule = optimizer.load_schedule(FIXTURE)

    def test_baseline_is_original_synthetic_fixture(self):
        self.assertEqual(hashlib.sha256(BASELINE.read_bytes()).hexdigest(),
                         "58baeb7a81a0c76bde1ff08a36fea900812b38bbd3f99d1e6657eece97871a84")

    def test_constructive_candidate_is_reproducible_feasible_and_workload_balanced(self):
        candidate = copy.deepcopy(self.baseline)
        candidate.grid = {}
        for pgy, night_range, weekend_range in [(1, 1, 1), (2, 0, 0), (3, 0, 2), (4, 0, 2)]:
            grid = optimizer._constructive_hint(self.baseline, pgy)
            self.assertEqual(grid, optimizer._constructive_hint(self.baseline, pgy))
            candidate.grid.update(grid)
            workloads = [optimizer.workload(optimizer.project_resident(candidate.slots, cells))
                         for cells in grid.values()]
            for metric, expected in [("night_shifts", night_range), ("weekend_shifts", weekend_range)]:
                values = [entry[metric] for entry in workloads]
                self.assertEqual(max(values) - min(values), expected, f"PGY{pgy} {metric}")
        self.assertEqual(optimizer.validate_schedule(candidate, self.baseline), [])

    def test_optimized_fixture_passes_every_confirmed_hard_constraint(self):
        self.assertEqual(optimizer.validate_schedule(self.schedule, self.baseline), [])

    def test_preserves_all_identities_calendar_and_literal_float_assignments(self):
        self.assertEqual(set(self.schedule.names), {f"R{pgy}-{choice}" for pgy in range(1, 5) for choice in range(1, 9)})
        self.assertEqual(self.schedule.names, self.baseline.names)
        self.assertEqual(self.schedule.slots, self.baseline.slots)
        for code, original in self.baseline.grid.items():
            self.assertEqual([n for n, cell in enumerate(self.schedule.grid[code]) if cell == "FLOAT"],
                             [n for n, cell in enumerate(original) if cell == "FLOAT"])

    def test_each_resident_has_two_single_vacations_and_one_protected_double_vacation(self):
        for code, cells in self.schedule.grid.items():
            vacation_starts = [entry["start"] for entry, label in zip(self.schedule.slots, cells)
                               if entry["kind"] == "weekday" and label == "VAC"]
            self.assertEqual(len(vacation_starts), 4, code)
            groups = []
            for start in vacation_starts:
                if groups and start - groups[-1][-1] == timedelta(days=7):
                    groups[-1].append(start)
                else:
                    groups.append([start])
            self.assertEqual(sorted(map(len, groups)), [1, 1, 2], code)
            projected_dates = {shift["date"] for shift in optimizer.project_resident(self.schedule.slots, cells)["shifts"]}
            for group in groups:
                if len(group) == 2:
                    weekend = {group[0] + timedelta(days=5), group[0] + timedelta(days=6)}
                    self.assertFalse(projected_dates & weekend, code)
                    for entry, label in zip(self.schedule.slots, cells):
                        if entry["start"] in weekend:
                            self.assertIn(label, {"", "P"}, code)

    def test_preserves_class_night_weekend_and_vacation_service_budgets(self):
        for pgy, hnf, hwn, hwd in [(1, 16, 28, 28), (2, 16, 16, 40),
                                   (3, 24, 24, 23), (4, 24, 24, 25)]:
            totals = Counter(cell.upper() for code, cells in self.schedule.grid.items()
                             if code.startswith(f"R{pgy}-") for cell in cells)
            for label, required in {"NF": 48, "SWN": 48, "SWD": 48, "HNF": hnf,
                                    "HWN": hwn, "HWD": hwd, "VAC": 32}.items():
                self.assertEqual(totals[label], required, f"PGY{pgy} {label} service budget")

    def test_non_float_weekdays_are_occupied_by_educational_work_or_vacation(self):
        weekday_labels = {"OB", "ONC", "GYN", "AMB", "NF", "HHOB", "HGYN", "HNF",
                          "REI", "UG", "ELECTIVE", "SWING", "US", "VAC"}
        for code, cells in self.schedule.grid.items():
            for scheduling_slot, label in zip(self.schedule.slots, cells):
                if scheduling_slot["kind"] == "weekday":
                    self.assertIn(label.upper(), weekday_labels, f"{code}: {scheduling_slot['start']}")
                elif scheduling_slot["kind"] == "weekend":
                    self.assertIn(label.upper(), {"", "P", "OFF", "SWD", "SWN", "HWD", "HWN"})

    def test_every_evaluable_daily_rolling_four_week_window_respects_limit(self):
        start = self.schedule.slots[0]["start"]
        end = self.schedule.slots[-1]["end"]
        for code, cells in self.schedule.grid.items():
            projected = optimizer.project_resident(self.schedule.slots, cells)
            windows = optimizer.duty_windows(projected, start, end)
            complete = [window for window in windows if window["complete"]]
            self.assertTrue(complete)
            self.assertTrue(any(not window["complete"] for window in windows))
            self.assertLessEqual(max(window["hours"] for window in complete), 320, code)

    def test_strong_weekend_nights_have_ambulatory_friday_coverage(self):
        for code, cells in self.schedule.grid.items():
            for index, label in enumerate(cells):
                if label == "SWN":
                    self.assertGreater(index, 0)
                    self.assertEqual(cells[index - 1], "AMB", code)
                    self.assertEqual(self.schedule.slots[index - 1]["end"] + timedelta(days=1),
                                     self.schedule.slots[index]["start"])

    def test_projected_work_assignments_never_overlap(self):
        for code, cells in self.schedule.grid.items():
            projected = optimizer.project_resident(self.schedule.slots, cells)
            counts = Counter(row["date"] for row in projected["shifts"])
            self.assertTrue(all(count == 1 for count in counts.values()), code)

    def test_baseline_reports_the_seventeen_documented_aggregate_staffing_shortfalls(self):
        self.assertEqual(len(optimizer.evaluate_schedule(self.baseline)["staffing_shortfalls"]), 17)

    def test_rotation_quotas_include_historical_weekend_cells_and_literal_durations(self):
        baseline = optimizer.evaluate_schedule(self.baseline)
        quotas = baseline["rotation_quotas"]
        self.assertEqual(quotas["per_pgy"]["1"]["HGYN"],
                         {"dated_cells": 56, "calendar_days": 244})
        self.assertEqual(sum(counts.get("HGYN", 0) for code, counts in
                             optimizer.education_counts(self.baseline).items() if code.startswith("R1-")), 44)
        self.assertEqual(sum(quotas["per_position"][f"R1-{n}"].get("HGYN", {}).get("dated_cells", 0)
                             for n in range(1, 9)), 56)

    def test_off_is_not_an_importable_annual_csv_label(self):
        changed = copy.deepcopy(self.schedule)
        weekend_index = next(n for n, entry in enumerate(changed.slots) if entry["kind"] == "weekend")
        changed.grid["R1-1"][weekend_index] = "OFF"
        errors = optimizer.validate_schedule(changed, self.baseline)
        self.assertTrue(any(error["constraint"] in {"unknown_rotation", "import_label"} for error in errors))

    def test_float_spelling_must_be_preserved_literally_in_csv(self):
        rows = copy.deepcopy(self.baseline.rows)
        for row in rows:
            if row and row[0] == "R1-1":
                row[row.index("FLOAT")] = "float"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "changed.csv"
            with path.open("w", newline="") as output:
                csv.writer(output).writerows(rows)
            try:
                changed = optimizer.load_schedule(path)
            except ValueError:
                return
            self.assertTrue(any(error["constraint"] == "fixed_float"
                                for error in optimizer.validate_schedule(changed, self.baseline)))

    def test_generation_entrypoint_defaults_to_synthetic_baseline(self):
        result = subprocess.run([sys.executable, str(ROOT / "priv/demo/generate_demo_schedule.py"), "--help"],
                                cwd=ROOT, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--baseline", result.stdout)
        self.assertNotIn("data/2026-2027-continuous.csv", result.stdout)

    def test_unknown_labels_are_validation_errors(self):
        changed = copy.deepcopy(self.schedule)
        changed.grid["R1-1"][0] = "NOT_A_ROTATION"
        self.assertTrue(optimizer.validate_schedule(changed, self.baseline))

    def test_missing_required_staffing_is_rejected(self):
        changed = copy.deepcopy(self.schedule)
        for code in changed.grid:
            if changed.grid[code][0] == "OB":
                changed.grid[code][0] = "OFF"
        self.assertTrue(optimizer.validate_schedule(changed, self.baseline))

    def test_same_class_duplicate_and_fixed_float_changes_are_rejected(self):
        duplicate = copy.deepcopy(self.schedule)
        duplicate.grid["R1-2"][0] = duplicate.grid["R1-1"][0] = "OB"
        self.assertTrue(optimizer.validate_schedule(duplicate, self.baseline))
        changed_float = copy.deepcopy(self.schedule)
        float_index = self.baseline.grid["R1-1"].index("FLOAT")
        changed_float.grid["R1-1"][float_index] = "OFF"
        self.assertTrue(optimizer.validate_schedule(changed_float, self.baseline))

    def test_infeasible_identity_contract_does_not_overwrite_output(self):
        invalid = copy.deepcopy(self.baseline)
        del invalid.grid["R1-1"]
        del invalid.names["R1-1"]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "schedule.csv"
            output.write_bytes(b"existing output must survive")
            with self.assertRaises(ValueError):
                optimizer.optimize(invalid, output, seconds=1, seed=2026)
            self.assertEqual(output.read_bytes(), b"existing output must survive")

    def test_custom_baseline_cannot_introduce_non_synthetic_names(self):
        invalid = copy.deepcopy(self.baseline)
        invalid.names["R1-1"] = "Not synthetic"
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "schedule.csv"
            output.write_bytes(b"existing synthetic fixture")
            with self.assertRaises(ValueError):
                optimizer.optimize(invalid, output, seconds=0, seed=2026)
            self.assertEqual(output.read_bytes(), b"existing synthetic fixture")


if __name__ == "__main__":
    unittest.main()
