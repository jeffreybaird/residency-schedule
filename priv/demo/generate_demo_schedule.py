#!/usr/bin/env python3
"""Regenerate priv/demo/demo_schedule.csv from a real schedule template.

The demo fixture is the real program template with the residents' names replaced
by invented ones, plus the minimal edits needed to satisfy the demo's realism
rules:

  * 8 residents per class (the template already has this)
  * at most one resident of a given class on a given rotation in a given slot
  * every cross-class pair of residents shares at least one slot on the same
    rotation

The June single-day columns that trail the previous academic year are dropped:
they carry one-off tokens ("Orient", "ADMIN/MFM", "GOG/Colpo") that the importer
does not recognise, and their transition-week doubling-up is not representative.

Usage: python3 priv/demo/generate_demo_schedule.py [template_csv]
"""

import csv
import itertools
import sys
from collections import defaultdict

TEMPLATE = "data/2026-2027-continuous.csv"
OUTPUT = "priv/demo/demo_schedule.csv"

# First column of the template that belongs to the new academic year.
FIRST_SLOT_COLUMN = 13

# Values that may legitimately repeat within a class in the same slot: they are
# call/absence markers rather than rotation assignments.
NON_ROTATION = {"P", "OFF", "Vac", "VAC", "FLOAT", ""}

NAMES = {
    "R4-1": "Wren Halloway",
    "R4-2": "Tobias Feld",
    "R4-3": "Ines Marchetti",
    "R4-4": "Desmond Achebe",
    "R4-5": "Anouk Verstraete",
    "R4-6": "Silas Okonkwo",
    "R4-7": "Marisol Ferreira",
    "R4-8": "Hugo Lindgren",
    "R3-1": "Priya Raghunathan",
    "R3-2": "Callum Vance",
    "R3-3": "Noor El-Amin",
    "R3-4": "Beatrix Sandoval",
    "R3-5": "Yusuf Demirci",
    "R3-6": "Clara Nyberg",
    "R3-7": "Theo Ramaswamy",
    "R3-8": "Imogen Blackwood",
    "R2-1": "Ezra Lindqvist",
    "R2-2": "Amara Osei",
    "R2-3": "Jonah Petrov",
    "R2-4": "Sylvie Tran",
    "R2-5": "Nadia Farouk",
    "R2-6": "Lucian Petrescu",
    "R2-7": "Aoife Gallagher",
    "R2-8": "Tomas Iglesias",
    "R1-1": "Rafael Duarte",
    "R1-2": "Margit Halvorsen",
    "R1-3": "Kwame Boateng",
    "R1-4": "Delphine Roux",
    "R1-5": "Solveig Aune",
    "R1-6": "Bashir Rahimi",
    "R1-7": "Cordelia Mbeki",
    "R1-8": "Emeka Nwachukwu",
}


def read_template(path):
    with open(path, newline="") as handle:
        return list(csv.reader(handle))


def resident_row(row):
    code = row[0].strip()
    return len(code) > 2 and code[0] == "R" and code[1].isdigit() and code[2] == "-"


def trim_to_academic_year(row, width):
    """Keep the label columns and the slot columns of the new academic year."""
    padded = row + [""] * (width - len(row))
    return [padded[0].strip(), padded[1].strip()] + padded[FIRST_SLOT_COLUMN:width]


def class_of(code):
    return code.split("-")[0]


def runs_of(cells):
    """Maximal ranges of consecutive identical non-empty cells."""
    found = []
    start = 0
    while start < len(cells):
        value = cells[start].strip()
        if not value:
            start += 1
            continue
        stop = start
        while stop + 1 < len(cells) and cells[stop + 1].strip() == value:
            stop += 1
        found.append((start, stop, value))
        start = stop + 1
    return found


def conflicts(grid):
    """(class, column, value) groups where a class doubles up on a rotation."""
    found = []
    columns = len(next(iter(grid.values())))
    for column in range(columns):
        holders = defaultdict(list)
        for code, cells in grid.items():
            value = cells[column].strip()
            if value not in NON_ROTATION:
                holders[(class_of(code), value)].append(code)
        for (klass, value), codes in holders.items():
            if len(codes) > 1:
                found.append((klass, column, value, codes))
    return found


def occupied_by_class(grid, klass, column, exclude):
    return {
        cells[column].strip()
        for code, cells in grid.items()
        if class_of(code) == klass and code != exclude
    }


def swap_is_legal(grid, code, span, value, other_span, other_value):
    """Both relabelled spans must stay unique within the resident's class."""
    klass = class_of(code)
    for start, stop, new_value in ((span[0], span[1], other_value), (other_span[0], other_span[1], value)):
        if new_value in NON_ROTATION:
            return False
        for column in range(start, stop + 1):
            if new_value in occupied_by_class(grid, klass, column, code):
                return False
    return True


def repair(grid):
    """Swap two same-length blocks inside one resident's row to break a clash.

    Swapping rather than relabelling keeps every resident's rotation totals
    identical to the real template, so the demo year still looks like a
    graduating curriculum.
    """
    unresolved = []
    for _ in range(200):
        remaining = conflicts(grid)
        if not remaining:
            return []
        progressed = False
        for klass, column, value, codes in remaining:
            # Move the higher-numbered resident: the lower number keeps the block.
            code = sorted(codes)[-1]
            cells = grid[code]
            span = next(
                (start, stop)
                for start, stop, run_value in runs_of(cells)
                if start <= column <= stop and run_value == value
            )
            length = span[1] - span[0]
            candidates = [
                (start, stop, run_value)
                for start, stop, run_value in runs_of(cells)
                if stop - start == length and run_value != value
            ]
            for start, stop, other_value in candidates:
                if swap_is_legal(grid, code, span, value, (start, stop), other_value):
                    for offset in range(length + 1):
                        cells[span[0] + offset] = other_value
                        cells[start + offset] = value
                    progressed = True
                    break
            if progressed:
                break
        if not progressed:
            unresolved = remaining
            break
    return unresolved


def unshared_cross_class_pairs(grid):
    missing = []
    for left, right in itertools.combinations(sorted(grid), 2):
        if class_of(left) == class_of(right):
            continue
        shared = any(
            a.strip() and a.strip() == b.strip()
            for a, b in zip(grid[left], grid[right])
        )
        if not shared:
            missing.append((left, right))
    return missing


def main():
    template = sys.argv[1] if len(sys.argv) > 1 else TEMPLATE
    rows = read_template(template)
    width = max(len(row) for row in rows)

    start_dates = trim_to_academic_year(rows[0], width)
    end_dates = trim_to_academic_year(rows[1], width)
    start_dates[0], start_dates[1] = "", "Dates"
    end_dates[0], end_dates[1] = "", ""

    residents = [trim_to_academic_year(row, width) for row in rows if resident_row(row)]
    grid = {row[0]: row[2:] for row in residents}

    unresolved = repair(grid)
    if unresolved:
        raise SystemExit(f"could not break {len(unresolved)} rotation clashes: {unresolved}")

    unshared = unshared_cross_class_pairs(grid)
    if unshared:
        raise SystemExit(f"{len(unshared)} cross-class pairs never share a rotation: {unshared}")

    per_class = defaultdict(int)
    for code in grid:
        per_class[class_of(code)] += 1
    if set(per_class.values()) != {8}:
        raise SystemExit(f"expected 8 residents per class, got {dict(per_class)}")

    # Commas are stripped from the event labels: the importer splits rows on
    # "," without honouring quoting, so an embedded comma shifts the columns.
    events = [cell.replace(",", " —") for cell in trim_to_academic_year(rows[2], width)]
    events[0], events[1] = "Special Events", ""

    output = [start_dates, end_dates, events]
    for code in sorted(grid, key=lambda c: (-int(c[1]), int(c.split("-")[1]))):
        output.append([code, NAMES[code]] + grid[code])

    with open(OUTPUT, "w", newline="") as handle:
        csv.writer(handle).writerows(output)

    print(f"wrote {OUTPUT}: {len(grid)} residents, {len(start_dates) - 2} slots")


if __name__ == "__main__":
    main()
