"""Apply the small set of final status business cells that own runtime numbers.

Other JSON fields remain owned by their JSON files. Sheet 90 is an archival
snapshot and is deliberately not read by this sync path.
"""
from __future__ import annotations

import json
import math
import re
from decimal import Decimal, InvalidOperation

SPECS = (
    ("01_棋子基础", "data/units/race_units.json", "units", ((6, "hp"), (10, "atk"), (14, "def"))),
    ("05_野怪", "data/pve/pve_monsters.json", "monsters", ((4, "hp"), (5, "atk"), (6, "def"))),
    ("08_法阵友军", "data/formation/formation_allies.json", "allies", ((4, "hp"), (5, "atk"), (6, "def"))),
)


def data_rows(book, sheet_name):
    for number, row in enumerate(book[sheet_name].iter_rows(min_row=4, values_only=True), 4):
        if row and row[0] not in (None, ""):
            yield number, row


def positive_int(value, label, *, allow_zero=False):
    if type(value) is not int or value < (0 if allow_zero else 1):
        raise ValueError(f"{label}: expected {'nonnegative' if allow_zero else 'positive'} whole number, got {value!r}")
    return value


def godot_round(value):
    return math.floor(value + 0.5)


def boss_base(spawn_value, label, *, allow_zero=False):
    spawn_value = positive_int(spawn_value, label, allow_zero=allow_zero)
    base = godot_round(spawn_value / 1.5)
    if godot_round(base * 1.5) != spawn_value:
        raise ValueError(f"{label}: {spawn_value} cannot be produced from an integer Boss base stat at x1.5")
    return base


def percent(value, label):
    try:
        if isinstance(value, str) and value.strip().endswith("%"):
            result = Decimal(value.strip()[:-1]) / 100
        elif type(value) in (int, float):
            result = Decimal(str(value))
        else:
            raise ValueError()
    except (InvalidOperation, ValueError):
        raise ValueError(f"{label}: expected a percentage such as 10% or a decimal such as 0.10, got {value!r}") from None
    if not Decimal(0) <= result <= Decimal(1):
        raise ValueError(f"{label}: percentage must be between 0% and 100%")
    return float(result), format((result * 100).normalize(), "f") + "%"


def golden_altar_cost(book):
    rows = [(number, row) for number, row in data_rows(book, "09_宝藏与套装")
            if row[0] == "money_golden_altar"]
    if len(rows) != 1:
        raise ValueError("09_宝藏与套装: expected one money_golden_altar row")
    number, row = rows[0]
    match = re.search(r"每次\s*-\s*(\d+)\s*法阵\s*HP", str(row[4]))
    if not match:
        raise ValueError(f"09_宝藏与套装 row {number}: write '每次 -N 法阵 HP' in effect column E")
    value = int(match.group(1))
    if not 1 <= value <= 10:
        raise ValueError(f"09_宝藏与套装 row {number}: altar HP cost must be 1–10")
    return value


def index_items(tables, file, collection):
    result = {}
    for item in tables[file][collection]:
        item_id = item["id"]
        if item_id in result:
            raise ValueError(f"{file}: duplicate runtime ID {item_id}")
        result[item_id] = item
    return result


def overlay_excel_owned(book, tables):
    """Update only allowlisted fields in memory; return human readable diffs."""
    changes = []

    def update(sheet, file, item_id, item, key, value):
        old = item[key]
        if type(old) is not type(value):
            raise ValueError(f"{sheet} {item_id} {key}: runtime type {type(old).__name__} differs from Excel")
        if old != value:
            changes.append({"sheet": sheet, "file": file, "id": item_id,
                            "field": key, "old": old, "new": value})
            item[key] = value

    for sheet, file, collection, fields in SPECS:
        items = index_items(tables, file, collection)
        seen = set()
        for number, row in data_rows(book, sheet):
            item_id = row[0]
            if not isinstance(item_id, str) or item_id not in items or item_id in seen:
                raise ValueError(f"{sheet} row {number}: unknown or duplicate ID {item_id!r}")
            seen.add(item_id)
            for column, key in fields:
                value = positive_int(row[column], f"{sheet} row {number} {item_id}.{key}", allow_zero=key == "def")
                if item_id == "human_death_servant" and key == "atk" and value != 1:
                    raise ValueError("01_棋子基础 human_death_servant.atk must remain 1 (fixed in UnitFactory)")
                update(sheet, file, item_id, items[item_id], key, value)
        if seen != set(items):
            raise ValueError(f"{sheet}: missing IDs {sorted(set(items) - seen)}")

    sheet = "06_Boss"
    items = index_items(tables, "data/boss/bosses.json", "bosses")
    seen = set()
    for number, row in data_rows(book, sheet):
        item_id = row[0]
        if not isinstance(item_id, str) or item_id not in items or item_id in seen:
            raise ValueError(f"{sheet} row {number}: unknown or duplicate ID {item_id!r}")
        seen.add(item_id)
        for column, key in ((3, "hp"), (4, "atk"), (14, "def")):
            value = boss_base(row[column], f"{sheet} row {number} {item_id}.{key}", allow_zero=key == "def")
            update(sheet, "data/boss/bosses.json", item_id, items[item_id], key, value)
    if seen != set(items):
        raise ValueError(f"{sheet}: missing IDs {sorted(set(items) - seen)}")

    sheet = "03_宠物与商城"
    items = index_items(tables, "data/pets/pets.json", "pets")
    seen = set()
    for number, row in data_rows(book, sheet):
        item_id = row[0]
        if not isinstance(item_id, str) or item_id not in items or item_id in seen:
            raise ValueError(f"{sheet} row {number}: unknown or duplicate ID {item_id!r}")
        seen.add(item_id)
        value, shown = percent(row[4], f"{sheet} row {number} {item_id}.value")
        for column in (5, 13):
            if shown not in str(row[column] or ""):
                raise ValueError(f"{sheet} row {number} {item_id}: update description column {column + 1} to include {shown}")
        update(sheet, "data/pets/pets.json", item_id, items[item_id], "value", value)
    if seen != set(items):
        raise ValueError(f"{sheet}: missing IDs {sorted(set(items) - seen)}")

    sheet = "09_宝藏与套装"
    items = index_items(tables, "data/treasure/treasures.json", "treasures")
    update(sheet, "data/treasure/treasures.json", "money_golden_altar",
           items["money_golden_altar"], "hp_cost", golden_altar_cost(book))
    return changes



def patch_json_scalars(source, changes, expected):
    """Replace only owned number tokens, preserving every other JSON byte."""
    updated = source
    for change in changes:
        item_id = re.escape(json.dumps(change["id"], ensure_ascii=False)[1:-1])
        field = re.escape(change["field"])
        pattern = re.compile(
            r'(\"id\"\s*:\s*\"' + item_id +
            r'\"(?:(?!\"id\"\s*:).)*?\"' + field +
            r'\"\s*:\s*)(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)',
            re.DOTALL,
        )
        matches = list(pattern.finditer(updated))
        if len(matches) != 1 or json.loads(matches[0].group(2)) != change["old"]:
            raise ValueError(f"Cannot safely patch {change['file']} {change['id']}.{change['field']}")
        match = matches[0]
        updated = updated[:match.start(2)] + json.dumps(change["new"]) + updated[match.end(2):]
    if json.loads(updated) != expected:
        raise ValueError("Patched JSON does not match validated Excel overlay")
    return updated
