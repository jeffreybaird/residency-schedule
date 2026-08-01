"""Generate a fully synthetic residency schedule CSV for the public demo.

Nothing here derives from real program data: names are invented, and the
rotation pattern is a mechanical round-robin over the abbreviations the
parser understands (see CsvParser @rotation_abbreviations).
"""
import csv
from datetime import date, timedelta

# 2030 sits outside NameNormalizer's {year, position} map, so the synthetic
# names below survive import instead of being rewritten to canonical ones.
START = date(2030, 7, 1)  # a Monday
WEEKS = 52

# Invented names, four per class.
RESIDENTS = {
    4: ["Wren Halloway", "Tobias Feld", "Ines Marchetti", "Desmond Achebe"],
    3: ["Priya Raghunathan", "Callum Vance", "Noor El-Amin", "Beatrix Sandoval"],
    2: ["Ezra Lindqvist", "Amara Osei", "Jonah Petrov", "Sylvie Tran"],
    1: ["Rafael Duarte", "Margit Halvorsen", "Kwame Boateng", "Delphine Roux"],
}

# Weekday rotation blocks, cycled per resident. Weekend codes are paired to
# whichever service the resident is on that block.
BLOCKS = [
    ("ONC", "HWD"),
    ("GYN", "SWD"),
    ("OB", "SWD"),
    ("NF", "P"),
    ("AMB", "SWN"),
    ("HGYN", "HWN"),
    ("Elective", ""),
    ("HNF", "P"),
    ("US", ""),
    ("REI", ""),
    ("UG", ""),
    ("Vac", ""),
    ("FLOAT", "FLOAT"),
]

SPECIAL_EVENTS = {6: "Retreat", 24: "CREOGS", 38: "Research Day"}


def slots():
    """Yield (start, end) for a weekday block then a weekend block, each week."""
    for w in range(WEEKS):
        monday = START + timedelta(weeks=w)
        yield monday, monday + timedelta(days=4)               # Mon–Fri
        yield monday + timedelta(days=5), monday + timedelta(days=6)  # Sat–Sun


all_slots = list(slots())

rows = []
rows.append(["", "Dates"] + [s.isoformat() for s, _ in all_slots])
rows.append(["", ""] + [e.isoformat() for _, e in all_slots])

events = ["Special Events", ""] + [""] * len(all_slots)
for idx, label in SPECIAL_EVENTS.items():
    events[idx + 2] = label
rows.append(events)

for year in (4, 3, 2, 1):
    for n, name in enumerate(RESIDENTS[year], start=1):
        # Offset each resident into the block cycle so services stay covered.
        offset = (year - 1) * 4 + (n - 1)
        cells = []
        for i in range(len(all_slots)):
            weekday, weekend = BLOCKS[(i // 2 + offset) % len(BLOCKS)]
            cells.append(weekday if i % 2 == 0 else weekend)
        rows.append([f"R{year}-{n}", name] + cells)

out = "priv/demo/demo_schedule.csv"
with open(out, "w", newline="") as f:
    csv.writer(f).writerows(rows)
print(f"wrote {out}: {len(rows)} rows, {len(all_slots)} slots")
