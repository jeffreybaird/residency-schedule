#!/usr/bin/env python3
"""Reproducible synthetic schedule optimization, never a clinical certification.

The Python model follows the application's canonical legacy shift projections.
FLOAT and work outside the supplied year are not evaluated. CP-SAT is imported
only when solving; the independent validator needs only the standard library.
"""

import argparse
import copy
import csv
import json
import os
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, timedelta
from itertools import combinations
from importlib.metadata import version
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT / "test/fixtures/demo_schedule_baseline.csv"
OUTPUT = ROOT / "priv/demo/demo_schedule.csv"
DAY = timedelta(days=1)
HOSPITAL = set("OB ONC GYN HGYN HHOB HNF NF SWD SWN HWD HWN UG".split())
NIGHTS = {"NF", "HNF", "SWN", "HWN"}
ABSENCE = {"", "P", "OFF", "VAC"}
WEEKEND = {"SWD", "SWN", "HWD", "HWN"}
CORE = {"OB", "ONC", "GYN", "AMB", "NF"}
SYNTHETIC_NAMES = {
    "R1-1": "Rafael Duarte", "R1-2": "Margit Halvorsen", "R1-3": "Kwame Boateng",
    "R1-4": "Delphine Roux", "R1-5": "Solveig Aune", "R1-6": "Bashir Rahimi",
    "R1-7": "Cordelia Mbeki", "R1-8": "Emeka Nwachukwu",
    "R2-1": "Ezra Lindqvist", "R2-2": "Amara Osei", "R2-3": "Jonah Petrov",
    "R2-4": "Sylvie Tran", "R2-5": "Nadia Farouk", "R2-6": "Lucian Petrescu",
    "R2-7": "Aoife Gallagher", "R2-8": "Tomas Iglesias",
    "R3-1": "Priya Raghunathan", "R3-2": "Callum Vance", "R3-3": "Noor El-Amin",
    "R3-4": "Beatrix Sandoval", "R3-5": "Yusuf Demirci", "R3-6": "Clara Nyberg",
    "R3-7": "Theo Ramaswamy", "R3-8": "Imogen Blackwood",
    "R4-1": "Wren Halloway", "R4-2": "Tobias Feld", "R4-3": "Ines Marchetti",
    "R4-4": "Desmond Achebe", "R4-5": "Anouk Verstraete", "R4-6": "Silas Okonkwo",
    "R4-7": "Marisol Ferreira", "R4-8": "Hugo Lindgren",
}
TARGETS = {
    1: dict(OB=6, ONC=6, GYN=6, HGYN=7, HNF=2, AMB=6, NF=6, VAC=4, SWING=2, US=3),
    2: dict(OB=6, ONC=6, GYN=6, HGYN=2, HHOB=6, HNF=2, AMB=6, NF=6, VAC=4, REI=4),
    3: dict(OB=6, ONC=6, GYN=6, HGYN=3, HNF=3, AMB=6, NF=6, VAC=4, ELECTIVE=4, UG=4),
    4: dict(OB=6, ONC=6, GYN=6, HGYN=6, HNF=3, AMB=6, NF=6, VAC=4, ELECTIVE=4, SWING=1),
}
BUDGETS = {
    y: dict(NF=48, SWN=48, SWD=48, HNF=hnf, HWN=hwn, HWD=hwd, VAC=32)
    for y, hnf, hwn, hwd in [(1, 16, 28, 28), (2, 16, 16, 40), (3, 24, 24, 23), (4, 24, 24, 25)]
}
KNOWN = set.union(ABSENCE, WEEKEND, {"FLOAT"}, *(set(t) for t in TARGETS.values()))


@dataclass
class Schedule:
    slots: list
    names: dict
    grid: dict
    rows: list


def dates(start, end):
    return [start + DAY * n for n in range((end - start).days + 1)]


def load_schedule(path):
    with open(path, newline="", encoding="utf-8") as source:
        rows = list(csv.reader(source))
    if len(rows) < 3:
        raise ValueError("Missing calendar rows")
    slots = []
    for column in range(2, len(rows[0])):
        if not rows[0][column].strip():
            continue
        start, end = date.fromisoformat(rows[0][column]), date.fromisoformat(rows[1][column])
        kind = "float" if (end - start).days == 6 else "weekend" if start.weekday() == 5 else "weekday"
        slots.append(dict(column=column, start=start, end=end, kind=kind))
    names, grid = {}, {}
    for row in rows[2:]:
        if not row or not row[0].startswith(tuple(f"R{y}-" for y in range(1, 5))):
            continue
        code = row[0].strip()
        if code in names:
            raise ValueError("Duplicate position code")
        names[code] = row[1]
        values = [row[s["column"]] if s["column"] < len(row) else "" for s in slots]
        grid[code] = [value if value.strip().upper() == "FLOAT" else value.strip().upper() for value in values]
    return Schedule(slots, names, grid, rows)


def project_resident(slots, cells):
    if len(slots) != len(cells):
        raise ValueError("Wrong assignment count")
    cells = [cell.strip().upper() for cell in cells]
    shifts, float_dates = [], set()
    by_start = {s["start"]: cell for s, cell in zip(slots, cells)}
    by_end = {s["end"]: cell for s, cell in zip(slots, cells)}
    for slot, rotation in zip(slots, cells):
        if rotation not in KNOWN:
            raise ValueError(f"Unknown rotation {rotation!r}")
        start, end = slot["start"], slot["end"]
        if rotation == "FLOAT":
            float_dates.update(dates(start, end))
            continue
        if rotation in ABSENCE:
            continue
        canonical_weekday = start.weekday() == 0 and (end - start).days == 4
        canonical_weekend = start.weekday() == 5 and (end - start).days == 1
        if rotation == "NF" and canonical_weekday:
            start, end = start - DAY, end - DAY
        elif rotation == "HNF":
            start -= DAY
        elif rotation == "HWN":
            end = start
        elif rotation == "AMB" and canonical_weekday and by_start.get(end + DAY) == "SWN":
            end -= DAY
        elif rotation == "SWN" and canonical_weekend and by_end.get(start - DAY) == "AMB":
            start, end = start - DAY, end - DAY
        for shift_date in dates(start, end):
            shifts.append(dict(date=shift_date, rotation=rotation, hours=12 if rotation in HOSPITAL else 8,
                               night=rotation in NIGHTS))
    return dict(shifts=sorted(shifts, key=lambda s: s["date"]), float_dates=float_dates)


def weekend_key(shift):
    day = shift["date"]
    if day.weekday() >= 5 or (day.weekday() == 4 and shift["night"]):
        return day + DAY * (5 - day.weekday())
    return None


def workload(projected):
    weekends = [weekend_key(s) for s in projected["shifts"]]
    return dict(night_shifts=sum(s["night"] for s in projected["shifts"]),
                weekend_shifts=sum(key is not None for key in weekends),
                weekends_worked=len({key for key in weekends if key is not None}))


def duty_windows(projected, start, end):
    hours = Counter()
    for shift in projected["shifts"]:
        hours[shift["date"]] += shift["hours"]
    return [dict(start=day, hours=sum(hours[d] for d in dates(day, day + 27 * DAY)),
                 complete=not any(d in projected["float_dates"] for d in dates(day, day + 27 * DAY)))
            for day in dates(start, end - 27 * DAY)]


def range_deviation(values):
    if not values:
        return 0, 0
    return max(values) - min(values), sum(abs(len(values) * v - sum(values)) for v in values)


def fairness_objective(workloads, education):
    totals = [0] * 8
    for year in range(1, 5):
        codes = [c for c in workloads if c.startswith(f"R{year}-")]
        for key, a, b in [("night_shifts", 0, 1), ("weekend_shifts", 2, 4), ("weekends_worked", 3, 5)]:
            spread, deviation = range_deviation([workloads[c][key] for c in codes])
            totals[a] += spread
            totals[b] += deviation
        labels = set().union(*(set(education.get(c, {})) for c in codes))
        for label in labels:
            spread, deviation = range_deviation([education.get(c, {}).get(label, 0) for c in codes])
            totals[6] += spread
            totals[7] += deviation
    return tuple(totals)


def education_target_deviation(education, targets):
    result = 0
    for year, target in targets.items():
        codes = [c for c in education if c.startswith(f"R{year}-")]
        for label in set(target).union(*(set(education[c]) for c in codes)):
            result += abs(sum(education[c].get(label, 0) for c in codes) - len(codes) * target.get(label, 0))
    return result


def education_counts(schedule):
    return {c: dict(Counter(cell for slot, cell in zip(schedule.slots, cells) if slot["kind"] == "weekday"))
            for c, cells in schedule.grid.items()}


def validate_schedule(schedule, baseline):
    errors = []
    expected = {f"R{y}-{n}" for y in range(1, 5) for n in range(1, 9)}
    def error(constraint, **details):
        errors.append(dict(constraint=constraint, **details))
    if set(schedule.grid) != expected or set(schedule.names) != expected:
        error("identities")
        return errors
    if schedule.names != baseline.names or schedule.names != SYNTHETIC_NAMES:
        error("synthetic_names")
    if schedule.slots != baseline.slots:
        error("calendar")
        return errors
    for code, cells in schedule.grid.items():
        if len(cells) != len(schedule.slots):
            error("assignment_count", code=code)
            return errors
        for index, (slot, cell) in enumerate(zip(schedule.slots, cells)):
            if cell not in KNOWN:
                error("unknown_rotation", code=code, slot=index, rotation=cell)
            if cell == "OFF":
                error("import_label", code=code, slot=index, rotation=cell)
            if (cell == "FLOAT") != (baseline.grid[code][index] == "FLOAT"):
                error("fixed_float", code=code, slot=index)
            allowed = set(TARGETS[int(code[1])]) if slot["kind"] == "weekday" else WEEKEND | (ABSENCE - {"OFF"}) if slot["kind"] == "weekend" else {"FLOAT"}
            if cell not in allowed:
                error("placement", code=code, slot=index, rotation=cell)
    for index, slot in enumerate(schedule.slots):
        if slot["kind"] == "float":
            continue
        for year in range(1, 5):
            values = Counter(cells[index] for code, cells in schedule.grid.items() if code.startswith(f"R{year}-"))
            for label, count in values.items():
                if label not in ABSENCE and count > 1:
                    error("same_class_overlap", pgy=year, slot=index, rotation=label, actual=count)
            required = CORE | ({"HHOB"} if year == 2 else set()) if slot["kind"] == "weekday" else {"SWD", "SWN"}
            for label in sorted(required):
                if values[label] != 1:
                    error("coverage", pgy=year, slot=index, rotation=label, actual=values[label], required=1)
    for year in range(1, 5):
        totals = Counter(cell for code, cells in schedule.grid.items() if code.startswith(f"R{year}-") for cell in cells)
        for label, required in BUDGETS[year].items():
            if totals[label] != required:
                error("service_budget", pgy=year, rotation=label, actual=totals[label], required=required)
    for code, cells in schedule.grid.items():
        by_end = {slot["end"]: cell for slot, cell in zip(schedule.slots, cells)}
        for slot, cell in zip(schedule.slots, cells):
            if cell == "SWN" and by_end.get(slot["start"] - DAY) != "AMB":
                error("ambulatory_weekend_pair", code=code, start=str(slot["start"]))
        try:
            projected = project_resident(schedule.slots, cells)
        except ValueError:
            continue
        for day, count in Counter(s["date"] for s in projected["shifts"]).items():
            if count > 1:
                error("working_date_overlap", code=code, date=str(day), count=count)
        for window in duty_windows(projected, schedule.slots[0]["start"], schedule.slots[-1]["end"]):
            if window["complete"] and window["hours"] > 320:
                error("duty_hours", code=code, start=str(window["start"]), hours=window["hours"])
    return errors


def evaluate_schedule(schedule):
    education = education_counts(schedule)
    workloads, windows, quality = {}, {}, {}
    for code, cells in schedule.grid.items():
        projected = project_resident(schedule.slots, cells)
        workloads[code] = workload(projected)
        windows[code] = duty_windows(projected, schedule.slots[0]["start"], schedule.slots[-1]["end"])
        weekdays = [(s, c) for s, c in zip(schedule.slots, cells) if s["kind"] != "weekend"]
        demanding = sum(all(c in HOSPITAL for _, c in weekdays[n:n + 3]) for n in range(len(weekdays) - 2))
        transitions = sum(a in {"NF", "HNF"} and b not in ABSENCE | NIGHTS | {"FLOAT"}
                          for (_, a), (_, b) in zip(weekdays, weekdays[1:]))
        recovery = sum(a in HOSPITAL and b == "VAC" for (_, a), (_, b) in zip(weekdays, weekdays[1:]))
        quality[code] = dict(demanding_triples=demanding, night_to_day=transitions,
                             recovery_opportunities=recovery, penalty=3 * demanding + 2 * transitions - recovery)
    shortfalls = []
    for index, slot in enumerate(schedule.slots):
        required = dict(OB=4, ONC=4, GYN=4, AMB=4, NF=4, HHOB=1) if slot["kind"] == "weekday" else dict(SWD=4, SWN=4) if slot["kind"] == "weekend" else {}
        counts = Counter(cells[index] for cells in schedule.grid.values())
        for label, count in required.items():
            if counts[label] < count:
                shortfalls.append(dict(start=str(slot["start"]), end=str(slot["end"]), rotation=label,
                                       required=count, actual=counts[label]))
    return dict(workloads=workloads, education=education, staffing_shortfalls=shortfalls,
                rotation_quotas=_rotation_quotas(schedule),
                fairness=list(fairness_objective(workloads, education)),
                target_deviation=education_target_deviation(education, TARGETS), quality=quality,
                maximum_evaluable_28_day_hours=max(w["hours"] for ws in windows.values() for w in ws if w["complete"]),
                incomplete_windows=sum(not w["complete"] for ws in windows.values() for w in ws),
                timing_diversity={str(y): {label: len({tuple(i for i, c in enumerate(cells) if c in labels)
                    for code, cells in schedule.grid.items() if code.startswith(f"R{y}-")})
                    for label, labels in [("vacation", {"VAC"}), ("night_float", {"NF", "HNF"})]}
                    for y in range(1, 5)})


def _rotation_quotas(schedule):
    """Count every dated source cell and its literal span, including misplaced baseline cells."""
    per_position, per_pgy = {}, {str(y): {} for y in range(1, 5)}
    for code, cells in schedule.grid.items():
        counts = {}
        for slot, label in zip(schedule.slots, cells):
            if not label:
                continue
            units = counts.setdefault(label, dict(dated_cells=0, calendar_days=0))
            units["dated_cells"] += 1
            units["calendar_days"] += (slot["end"] - slot["start"]).days + 1
        per_position[code] = counts
        for label, units in counts.items():
            total = per_pgy[code[1]].setdefault(label, dict(dated_cells=0, calendar_days=0))
            for key, value in units.items():
                total[key] += value
    return dict(per_position=per_position, per_pgy=per_pgy)


def _atomic_write(schedule, output):
    rows = copy.deepcopy(schedule.rows)
    for row in rows:
        if row and row[0] in schedule.grid:
            row[1] = schedule.names[row[0]]
            for slot, cell in zip(schedule.slots, schedule.grid[row[0]]):
                row[slot["column"]] = "Elective" if cell == "ELECTIVE" else "Vac" if cell == "VAC" else cell
    output = Path(output)
    with tempfile.NamedTemporaryFile(mode="w", newline="", encoding="utf-8", dir=output.parent, delete=False) as target:
        temporary = target.name
        try:
            csv.writer(target).writerows(rows)
            target.flush()
            os.fsync(target.fileno())
        except BaseException:
            os.unlink(temporary)
            raise
    os.replace(temporary, output)


def optimize(baseline, output_path, seconds=60, seed=2026, deterministic_time=1.0):
    expected = {f"R{y}-{n}" for y in range(1, 5) for n in range(1, 9)}
    if set(baseline.grid) != expected or set(baseline.names) != expected:
        raise ValueError("Infeasible identity contract: exactly eight positions per class required")
    if baseline.names != SYNTHETIC_NAMES:
        raise ValueError("The demo baseline must contain only the established synthetic resident names")
    from ortools.sat.python import cp_model
    result = copy.deepcopy(baseline)
    metadata = []
    for year in range(1, 5):
        solved, stages = _solve_class(cp_model, baseline, year, seconds, seed, deterministic_time)
        result.grid.update(solved)
        metadata.append(dict(pgy=year, stages=stages))
    errors = validate_schedule(result, baseline)
    if errors:
        raise ValueError(f"Hard validation failed; output untouched: {errors[:10]}")
    report = dict(seed=seed, workers=1, seconds_per_class_stage=seconds,
                deterministic_time_per_stage=deterministic_time, ortools_version=version("ortools"), solver=metadata,
                before=evaluate_schedule(baseline), after=evaluate_schedule(result),
                baseline_violations=validate_schedule(baseline, baseline), after_violations=[])
    _atomic_write(result, output_path)
    return report


def _solve_class(cp_model, baseline, year, seconds, seed, deterministic_time=1.0):
    """Staffing and fairness separate by PGY; quality refinement is classwise.

    A time-limited incumbent is never represented as a proven optimum. Optimizing
    each class's worst penalty is a heuristic for the global worst-then-total
    quality objective: this restricted search may miss a better global total.
    """
    model = cp_model.CpModel()
    slots = baseline.slots
    codes = [f"R{year}-{n}" for n in range(1, 9)]
    active = [i for i, slot in enumerate(slots) if slot["kind"] != "float"]
    weekdays = [i for i in active if slots[i]["kind"] == "weekday"]
    weekends = [i for i in active if slots[i]["kind"] == "weekend"]
    options = {i: sorted(TARGETS[year]) if i in weekdays else ["", "HWD", "HWN", "SWD", "SWN"] for i in active}
    x = {(r, i, label): model.new_bool_var(f"{r}_{i}_{label}") for r in range(8) for i in active for label in options[i]}
    hint = _constructive_hint(baseline, year)
    for (r, i, label), var in x.items():
        model.add_hint(var, int(hint[codes[r]][i] == label))
    for r in range(8):
        for i in active:
            model.add_exactly_one(x[r, i, label] for label in options[i])
    for i in active:
        required = CORE | ({"HHOB"} if year == 2 else set()) if i in weekdays else {"SWD", "SWN"}
        for label in options[i]:
            if label in ABSENCE:
                continue
            terms = [x[r, i, label] for r in range(8)]
            model.add(sum(terms) == 1) if label in required else model.add(sum(terms) <= 1)
    for label, total in BUDGETS[year].items():
        model.add(sum(var for (r, i, key), var in x.items() if key == label) == total)
    for r in range(8):
        for i in weekdays:
            j = next(j for j in weekends if slots[j]["start"] == slots[i]["end"] + DAY)
            model.add(x[r, i, "AMB"] == x[r, j, "SWN"])
    # Each potential assignment has an exact independent projected footprint:
    # AMB/SWN are linked above, so their Friday boundary is never ambiguous.
    footprints = {}
    for i in active:
        for label in options[i]:
            slot = slots[i]
            if label == "AMB":
                shifts = [dict(date=d, hours=8, night=False, rotation=label) for d in dates(slot["start"], slot["end"] - DAY)]
            elif label == "SWN":
                shifts = [dict(date=d, hours=12, night=True, rotation=label) for d in dates(slot["start"] - DAY, slot["end"] - DAY)]
            else:
                shifts = project_resident([slot], [label])["shifts"]
            footprints[i, label] = shifts
    workload_values = {key: [] for key in ["night_shifts", "weekend_shifts", "weekends_worked"]}
    education = defaultdict(list)
    penalties = []
    float_dates = set(d for s in slots if s["kind"] == "float" for d in dates(s["start"], s["end"]))
    for r in range(8):
        by_date, weekend_terms = defaultdict(list), defaultdict(list)
        for (i, label), shifts in footprints.items():
            for shift in shifts:
                by_date[shift["date"]].append((x[r, i, label], shift["hours"]))
                key = weekend_key(shift)
                if key is not None:
                    weekend_terms[key].append(x[r, i, label])
        for terms in by_date.values():
            model.add(sum(var for var, hours in terms) <= 1)
        for start in dates(slots[0]["start"], slots[-1]["end"] - 27 * DAY):
            window = dates(start, start + 27 * DAY)
            if not float_dates.intersection(window):
                model.add(sum(var * hours for d in window for var, hours in by_date[d]) <= 320)
        for key in ["night_shifts", "weekend_shifts"]:
            value = model.new_int_var(0, 500, f"{r}_{key}")
            model.add(value == sum(x[r, i, label] * workload(dict(shifts=shifts))[key] for (i, label), shifts in footprints.items()))
            workload_values[key].append(value)
        worked = []
        for key, terms in weekend_terms.items():
            flag = model.new_bool_var(f"{r}_weekend_{key}")
            model.add_max_equality(flag, list(set(terms)))
            worked.append(flag)
        value = model.new_int_var(0, 54, f"{r}_weekends_worked")
        model.add(value == sum(worked))
        workload_values["weekends_worked"].append(value)
        for label in TARGETS[year]:
            count = model.new_int_var(0, 48, f"{r}_count_{label}")
            model.add(count == sum(x[r, i, label] for i in weekdays))
            education[label].append(count)
        # Coarse sequence metrics are explicitly subordinate to fairness.
        demanding, night = {}, {}
        for i in weekdays:
            demanding[i] = model.new_bool_var(f"{r}_demand_{i}")
            model.add(demanding[i] == sum(x[r, i, label] for label in options[i] if label in HOSPITAL))
            night[i] = model.new_bool_var(f"{r}_night_{i}")
            model.add(night[i] == x[r, i, "NF"] + x[r, i, "HNF"])
        points = []
        for a, b, c in zip(weekdays, weekdays[1:], weekdays[2:]):
            if slots[c]["start"] - slots[a]["start"] == 14 * DAY:
                flag = model.new_bool_var(f"{r}_triple_{a}")
                model.add_min_equality(flag, [demanding[a], demanding[b], demanding[c]])
                points.append(3 * flag)
        for a, b in zip(weekdays, weekdays[1:]):
            if slots[b]["start"] - slots[a]["start"] != 7 * DAY:
                continue
            flag = model.new_bool_var(f"{r}_transition_{a}")
            model.add_min_equality(flag, [night[a], 1 - night[b] - x[r, b, "VAC"]])
            recovery = model.new_bool_var(f"{r}_recovery_{a}")
            model.add_min_equality(recovery, [demanding[a], x[r, b, "VAC"]])
            points.extend([2 * flag, -recovery])
        penalty = model.new_int_var(-48, 240, f"{r}_penalty")
        model.add(penalty == sum(points))
        penalties.append(penalty)
    def spread_deviation(values, name):
        low, high = model.new_int_var(0, 500, name + "_min"), model.new_int_var(0, 500, name + "_max")
        model.add_min_equality(low, values)
        model.add_max_equality(high, values)
        deviations = []
        for n, value in enumerate(values):
            deviation = model.new_int_var(0, 4000, f"{name}_dev_{n}")
            model.add_abs_equality(deviation, 8 * value - sum(values))
            deviations.append(deviation)
        return high - low, sum(deviations)
    night_range, night_dev = spread_deviation(workload_values["night_shifts"], "night")
    night_total = 5 * BUDGETS[year]["NF"] + 6 * BUDGETS[year]["HNF"] + 2 * BUDGETS[year]["SWN"] + BUDGETS[year]["HWN"]
    remainder = night_total % 8
    model.add(night_range >= int(remainder != 0))
    model.add(night_dev >= 2 * remainder * (8 - remainder))
    hint_nights = [workload(project_resident(slots, hint[code]))["night_shifts"] for code in codes]
    model.add(night_range <= max(hint_nights) - min(hint_nights))
    weekend_range, weekend_dev = spread_deviation(workload_values["weekend_shifts"], "weekend")
    worked_range, worked_dev = spread_deviation(workload_values["weekends_worked"], "worked")
    educational_ranges, educational_devs, target_devs = [], [], []
    for label, values in education.items():
        spread, deviation = spread_deviation(values, label)
        educational_ranges.append(spread)
        educational_devs.append(deviation)
        target = model.new_int_var(0, 384, "target_" + label)
        model.add_abs_equality(target, sum(values) - 8 * TARGETS[year][label])
        target_devs.append(target)
    worst = model.new_int_var(-48, 240, "worst")
    model.add_max_equality(worst, penalties)
    penalty_low = model.new_int_var(-48, 240, "penalty_low")
    model.add_min_equality(penalty_low, penalties)
    # Night timing is already disjoint within each class by service uniqueness.
    # Its pairwise Hamming sum is constant, so optimize only vacation diversity.
    diverse = []
    for left, right in combinations(range(8), 2):
        for i in weekdays:
            for label in ["VAC"]:
                flag = model.new_bool_var(f"diff_{left}_{right}_{i}_{label}")
                model.add_abs_equality(flag, x[left, i, label] - x[right, i, label])
                diverse.append(flag)
    objectives = [("night_range", night_range), ("night_deviation", night_dev),
                  ("weekend_shift_range", weekend_range), ("weekends_worked_range", worked_range),
                  ("weekend_shift_deviation", weekend_dev), ("weekends_worked_deviation", worked_dev),
                  ("educational_target_deviation", sum(target_devs)),
                  ("educational_range", sum(educational_ranges)), ("educational_deviation", sum(educational_devs)),
                  ("worst_sequence_penalty", worst), ("total_sequence_penalty", sum(penalties)),
                  ("sequence_penalty_range", worst - penalty_low), ("negative_vacation_timing_diversity", -sum(diverse))]
    stages = []
    solution = {key: int(hint[codes[key[0]]][key[1]] == key[2]) for key in x}
    previous_solver = None
    # Complete all auxiliary variable hints with a fast fixed-assignment solve.
    # Partial hints alone can spend a short search budget finding auxiliary
    # values despite the already valid assignment-level incumbent.
    completion = cp_model.CpSolver()
    completion.parameters.max_time_in_seconds = seconds
    completion.parameters.max_deterministic_time = deterministic_time
    completion.parameters.num_search_workers = 1
    completion.parameters.random_seed = seed
    completion.parameters.fix_variables_to_their_hinted_value = True
    completion_status = completion.solve(model)
    if completion_status in (cp_model.INFEASIBLE, cp_model.MODEL_INVALID):
        raise ValueError(f"PGY {year}: constructive model {completion.status_name(completion_status)}; output untouched")
    if completion_status in (cp_model.FEASIBLE, cp_model.OPTIMAL):
        model.clear_hints()
        for index in range(len(model.proto.variables)):
            var = model.get_int_var_from_proto_index(index)
            model.add_hint(var, completion.value(var))
        previous_solver = completion
    for name, objective in objectives:
        if previous_solver is not None:
            model.add(objective <= previous_solver.value(objective))
        model.minimize(objective)
        solver = cp_model.CpSolver()
        solver.parameters.max_time_in_seconds = seconds
        solver.parameters.max_deterministic_time = deterministic_time
        solver.parameters.num_search_workers = 1
        solver.parameters.random_seed = seed
        solver.parameters.cp_model_presolve = False
        solver.parameters.search_branching = cp_model.HINT_SEARCH
        status = solver.solve(model)
        if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
            if status != cp_model.UNKNOWN:
                raise ValueError(f"PGY {year}: {solver.status_name(status)}; output untouched")
            stages.append(dict(objective=name, status=solver.status_name(status),
                               retained="constructive_incumbent" if previous_solver is None else "previous_feasible_incumbent"))
            print(f"PGY {year} {name}: {solver.status_name(status)}; retaining validated incumbent", flush=True)
            break
        value = int(round(solver.objective_value))
        stages.append(dict(objective=name, value=value, bound=solver.best_objective_bound, status=solver.status_name(status),
                           deterministic_time=solver.response_proto.deterministic_time,
                           wall_limit_reached=solver.wall_time >= seconds))
        solution = {key: solver.value(var) for key, var in x.items()}
        previous_solver = solver
        model.add(objective <= value)
        model.clear_hints()
        for index in range(len(model.proto.variables)):
            var = model.get_int_var_from_proto_index(index)
            model.add_hint(var, solver.value(var))
        print(f"PGY {year} {name}: {value} ({solver.status_name(status)}, bound {solver.best_objective_bound})", flush=True)
    grid = {code: ["FLOAT" if s["kind"] == "float" else "" for s in slots] for code in codes}
    for (r, i, label), selected in solution.items():
        if selected:
            grid[codes[r]][i] = label
    return grid, stages


def _constructive_hint(baseline, year):
    """Balanced cyclic starting point; only a hint, never a solver restriction.

    A one-position shift after 24 weeks balances parity in six-week extra-service
    patterns. Core positions keep weekend duty away from the next Sunday's NF
    and HNF. Highland weekend totals are distributed across their eligible rows.
    """
    extras = {
        1: [["HGYN", "HNF", "VAC"], ["HGYN", "US", "VAC"], ["HGYN", "US", "SWING"]],
        2: [["HHOB", "HGYN", "HNF"], ["HHOB", "REI", "VAC"], ["HHOB", "REI", "VAC"]],
        3: [["HGYN", "HNF", "VAC"], ["HGYN", "ELECTIVE", "UG"],
            ["HNF", "VAC", "ELECTIVE"], ["HGYN", "VAC", "UG"],
            ["HNF", "ELECTIVE", "UG"], ["VAC", "ELECTIVE", "UG"]],
        4: [["HGYN", "HNF", "VAC"], ["HGYN", "HNF", "ELECTIVE"],
            ["HGYN", "HNF", "VAC"], ["HGYN", "ELECTIVE", "VAC"],
            ["HGYN", "ELECTIVE", "VAC"], ["HGYN", "ELECTIVE", "SWING"]],
    }
    codes = [f"R{year}-{n}" for n in range(1, 9)]
    grid = {code: ["FLOAT" if s["kind"] == "float" else "" for s in baseline.slots] for code in codes}
    candidates = {"HWD": defaultdict(list), "HWN": defaultdict(list)}
    weekdays = [i for i, slot in enumerate(baseline.slots) if slot["kind"] == "weekday"]
    by_start = {slot["start"]: i for i, slot in enumerate(baseline.slots)}
    for week, i in enumerate(weekdays):
        positions = ["OB", "ONC", "GYN", "AMB", "NF"] + extras[year][week % len(extras[year])]
        weekend = by_start[baseline.slots[i]["end"] + DAY]
        for r, code in enumerate(codes):
            position = (r + week + week // 24) % 8
            grid[code][i] = positions[position]
            if position in [0, 3]:
                grid[code][weekend] = "SWD" if position == 0 else "SWN"
            if position in [1, 2]:
                candidates["HWD" if position == 1 else "HWN"][code].append(weekend)
    for label, per_code in candidates.items():
        total = BUDGETS[year][label]
        for r, code in enumerate(codes):
            # PGY1 HWN remainder complements HWD so weekend-shift spread is one.
            rank = 7 - r if year == 1 and label == "HWN" else r
            count = total // 8 + int(rank < total % 8)
            indices = per_code[code]
            for n in range(count):
                grid[code][indices[n * len(indices) // count]] = label
    grid = _balance_worked_weekends(grid, baseline.slots)
    return _balance_week_blocks(grid, baseline.slots)


def _balance_worked_weekends(grid, slots):
    """Move Highland weekend duty to reduce weekend-count inequality only.

    Every move preserves each person's night and weekend shift counts and every
    educational assignment. Coverage, no-double-duty and modeled hours are
    checked before accepting it; this is a deterministic local search.
    """
    codes = sorted(grid)
    weekends = [i for i, slot in enumerate(slots) if slot["kind"] == "weekend"]
    counts = {code: workload(project_resident(slots, cells))["weekends_worked"] for code, cells in grid.items()}
    improved = True
    while improved:
        improved = False
        before = range_deviation(list(counts.values()))
        for code in sorted(codes, key=lambda c: (-counts[c], c)):
            for old in weekends:
                label = grid[code][old]
                if label not in {"HWD", "HWN"}:
                    continue
                for new in weekends:
                    if grid[code][new] or any(grid[other][new] == label for other in codes):
                        continue
                    cells = list(grid[code])
                    cells[old], cells[new] = "", label
                    projected = project_resident(slots, cells)
                    count = workload(projected)["weekends_worked"]
                    candidate_counts = [count if c == code else counts[c] for c in codes]
                    if range_deviation(candidate_counts) >= before:
                        continue
                    if any(n > 1 for n in Counter(s["date"] for s in projected["shifts"]).values()):
                        continue
                    windows = duty_windows(projected, slots[0]["start"], slots[-1]["end"])
                    if any(w["complete"] and w["hours"] > 320 for w in windows):
                        continue
                    grid[code], counts[code] = cells, count
                    improved = True
                    break
                if improved:
                    break
            if improved:
                break
    return grid


def _balance_week_blocks(grid, slots):
    """Swap whole class weeks to improve weekend fairness without quota changes."""
    weekday_indices = [i for i, slot in enumerate(slots) if slot["kind"] == "weekday"]
    weekend_for = {i: next(j for j, s in enumerate(slots) if s["start"] == slots[i]["end"] + DAY)
                   for i in weekday_indices}
    def score(candidate):
        return range_deviation([workload(project_resident(slots, cells))["weekends_worked"] for cells in candidate.values()])
    current = score(grid)
    while current != (0, 0):
        improved = False
        for left, right in combinations(weekday_indices, 2):
            candidate = {code: list(cells) for code, cells in grid.items()}
            for cells in candidate.values():
                cells[left], cells[right] = cells[right], cells[left]
                a, b = weekend_for[left], weekend_for[right]
                cells[a], cells[b] = cells[b], cells[a]
            after = score(candidate)
            if after >= current:
                continue
            compatible = True
            for cells in candidate.values():
                projected = project_resident(slots, cells)
                if any(n > 1 for n in Counter(s["date"] for s in projected["shifts"]).values()):
                    compatible = False
                    break
                if any(w["complete"] and w["hours"] > 320 for w in duty_windows(projected, slots[0]["start"], slots[-1]["end"])):
                    compatible = False
                    break
            if compatible:
                grid, current, improved = candidate, after, True
                break
        if not improved:
            break
    return grid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--report", type=Path, default=ROOT / ".docs/demo-schedule-optimization-metrics.json")
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--deterministic-time", type=float, default=1.0,
                        help="CP-SAT deterministic work budget per objective; --seconds is an emergency wall cap")
    parser.add_argument("--seed", type=int, default=2026)
    args = parser.parse_args()
    report = optimize(load_schedule(args.baseline), args.output, seconds=args.seconds, seed=args.seed,
                      deterministic_time=args.deterministic_time)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
