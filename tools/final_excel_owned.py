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
)

# 06_Boss!B16:E51 is the editable skill input table. Column A stays blank so
# the existing one-row-per-boss summary parser does not treat these as bosses.
BOSS_SKILL_FIELDS = {
    "boss_meteor_caster": ("skill_cd", "skill_damage", "aoe_radius"),
    "boss_thunder_core": ("hit_threshold", "skill_damage", "interrupt_chance", "splash_damage", "splash_radius"),
    "boss_mirror_lord": ("clone_per_missing_hp_pct", "clone_hp_pct", "clone_atk_pct", "clone_def"),
    "boss_holy_priest": ("skill_cd", "heal_pct", "shield_pct"),
    "boss_rage_beast": ("atk_per_hit", "aspd_per_hit", "max_stacks"),
    "boss_blood_demon": ("trigger_hp_pct", "atk_bonus", "aspd_bonus", "lifesteal"),
    "boss_soul_devourer": ("kill_heal_pct", "atk_stack", "aspd_stack"),
    "boss_twin_gate": ("revive_delay", "revive_hp_pct", "revives_per_twin", "cleave_atk_pct", "cleave_distance", "cleave_start_half_width", "cleave_end_half_width"),
    "boss_apocalypse": ("skill_cd", "charge_sec", "charge_shield_pct", "damage_atk_pct"),
}
BOSS_PERCENT_FIELDS = {
    "interrupt_chance", "clone_per_missing_hp_pct", "clone_hp_pct", "clone_atk_pct",
    "heal_pct", "shield_pct", "atk_per_hit", "trigger_hp_pct", "atk_bonus",
    "lifesteal", "kill_heal_pct", "atk_stack", "revive_hp_pct",
    "cleave_atk_pct", "charge_shield_pct", "damage_atk_pct",
}


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


def skill_damage_percent(value, label):
    """Read the whole percent shown in a skill input cell (160 means 160%)."""
    if isinstance(value, bool) or type(value) not in (int, float):
        raise ValueError(f"{label}: enter a number such as 160 for 160%")
    try:
        amount = Decimal(str(value))
    except InvalidOperation:
        raise ValueError(f"{label}: enter a number such as 160 for 160%") from None
    if not Decimal(10) <= amount <= Decimal(1000):
        raise ValueError(f"{label}: enter a whole percent from 10 to 1000 (160 means 160%; do not type 160%)")
    return float(amount / 100)


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


def corrosive_bleed_bonus(book):
    rows = [(number, row) for number, row in data_rows(book, "09_宝藏与套装")
            if row[0] == "ctrl_corrosive_needle"]
    if len(rows) != 1:
        raise ValueError("09_宝藏与套装: expected one ctrl_corrosive_needle row")
    number, row = rows[0]
    match = re.search(r"普攻已流血目标时伤害\s*\+\s*(\d+(?:\.\d+)?)%", str(row[4]))
    if not match:
        raise ValueError(f"09_宝藏与套装 row {number}: write '普攻已流血目标时伤害+15%' in effect column E")
    value, _ = percent(match.group(1) + "%", f"09_宝藏与套装 row {number} ctrl_corrosive_needle")
    if value <= 0.0:
        raise ValueError(f"09_宝藏与套装 row {number}: bleed bonus must be positive")
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

    expected_skills = {(item_id, key) for item_id, keys in BOSS_SKILL_FIELDS.items() for key in keys}
    seen_skills = set()
    for number in range(16, book[sheet].max_row + 1):
        ws = book[sheet]
        item_id, key, raw = (ws.cell(number, col).value for col in (2, 3, 4))
        if item_id is None and key is None and raw is None:
            continue
        pair = (item_id, key)
        if pair not in expected_skills or pair in seen_skills:
            raise ValueError(f"{sheet} row {number}: unknown or duplicate skill parameter {pair!r}")
        seen_skills.add(pair)
        old = items[item_id][key]
        label = f"{sheet} D{number} {item_id}.{key}"
        if isinstance(raw, bool) or type(raw) not in (int, float) or not math.isfinite(raw):
            raise ValueError(f"{label}: enter a finite number")
        if type(old) is int:
            if type(raw) is not int or raw < (0 if key == "clone_def" else 1):
                raise ValueError(f"{label}: enter a nonnegative whole number" if key == "clone_def" else f"{label}: enter a positive whole number")
            value = raw
        else:
            if key in BOSS_PERCENT_FIELDS:
                if not 0.0 <= raw <= 300.0:
                    raise ValueError(f"{label}: enter a whole percentage from 0 to 300 (20 means 20%)")
                value = float(Decimal(str(raw)) / 100)
                if key == "clone_per_missing_hp_pct" and value <= 0:
                    raise ValueError(f"{label}: clone threshold must be above 0%")
            else:
                value = float(raw)
            if key not in BOSS_PERCENT_FIELDS and value <= 0:
                raise ValueError(f"{label}: enter a positive number")
        update(sheet, "data/boss/bosses.json", item_id, items[item_id], key, value)
    if seen_skills != expected_skills:
        raise ValueError(f"{sheet}: missing skill parameters {sorted(expected_skills - seen_skills)}")

    sheet = "03_宠物技能"
    items = index_items(tables, "data/pets/pets.json", "pets")
    seen = set()
    for number, row in data_rows(book, sheet):
        item_id = row[0]
        if not isinstance(item_id, str) or item_id not in items or item_id in seen:
            raise ValueError(f"{sheet} row {number}: unknown or duplicate ID {item_id!r}")
        seen.add(item_id)
        value, shown = percent(row[4], f"{sheet} row {number} {item_id}.value")
        for column in (5, 9):
            if shown not in str(row[column] or ""):
                raise ValueError(f"{sheet} row {number} {item_id}: update description column {column + 1} to include {shown}")
        update(sheet, "data/pets/pets.json", item_id, items[item_id], "value", value)
    if seen != set(items):
        raise ValueError(f"{sheet}: missing IDs {sorted(set(items) - seen)}")

    sheet = "09_宝藏与套装"
    items = index_items(tables, "data/treasure/treasures.json", "treasures")
    update(sheet, "data/treasure/treasures.json", "money_golden_altar",
           items["money_golden_altar"], "hp_cost", golden_altar_cost(book))
    update(sheet, "data/treasure/treasures.json", "ctrl_corrosive_needle",
           items["ctrl_corrosive_needle"], "bonus_vs_bleeding", corrosive_bleed_bonus(book))

    sheet = "02_棋子技能"
    skill_rows = {item_id: [(number, row) for number, row in data_rows(book, sheet) if row[0] == item_id]
                  for item_id in ("dark_dragon", "human_cleric", "undead_bomb")}
    units = index_items(tables, "data/units/race_units.json", "units")
    for item_id, skill_id, key in (("dark_dragon", "black_hole", "damage_atk_pct"),
                                   ("human_cleric", "every_fifth_group_heal", "heal_pct"),
                                   ("undead_bomb", "death_poison_explosion", "damage_atk_pct")):
        rows = skill_rows[item_id]
        if len(rows) != 1 or rows[0][1][3] != skill_id:
            raise ValueError(f"{sheet}: expected one {item_id} / {skill_id} row")
        number, row = rows[0]
        for column in (15, 16):
            cell = book[sheet].cell(row=number, column=column)
            if "%" in cell.number_format:
                raise ValueError(f"{sheet} {cell.coordinate}: use a plain number such as 160, not an Excel percent-formatted value")
        base = skill_damage_percent(row[14] if len(row) > 14 else None,
                                    f"{sheet} O{number} {item_id} 1–3★")
        star4 = skill_damage_percent(row[15] if len(row) > 15 else None,
                                     f"{sheet} P{number} {item_id} 4★")
        if key == "heal_pct" and (base > 1.0 or star4 > 1.0):
            raise ValueError(f"{sheet} {item_id}: healing percent must be at most 100")
        base_text = f"{int(round(base * 100))}%"
        star4_text = f"{int(round(star4 * 100))}%"
        if item_id != "dark_dragon" and (base_text not in str(row[6]) or base_text not in str(row[11])
                                          or star4_text not in str(row[12])):
            raise ValueError(f"{sheet} {item_id}: skill descriptions must follow O{number}/P{number}")
        unit = units[item_id]
        update(sheet, "data/units/race_units.json", item_id, unit, key, base)
        old_star4 = unit["star4"][key]
        if isinstance(old_star4, bool) or not isinstance(old_star4, (int, float)):
            raise ValueError(f"{item_id} star4.{key} must be a number")
        if old_star4 != star4:
            changes.append({"sheet": sheet, "file": "data/units/race_units.json",
                            "id": item_id, "field": f"star4.{key}",
                            "old": old_star4, "new": star4})
            unit["star4"][key] = star4
    return changes



def patch_json_scalars(source, changes, expected):
    """Replace only owned number tokens, preserving every other JSON byte."""
    updated = source
    for change in changes:
        if change["id"] in ("dark_dragon", "human_cleric", "undead_bomb") and change["field"] in ("damage_atk_pct", "star4.damage_atk_pct", "heal_pct", "star4.heal_pct"):
            item_id = change["id"]
            key = change["field"].removeprefix("star4.")
            anchor = list(re.finditer(r'\{\s*"id"\s*:\s*"' + re.escape(item_id) + r'"', updated))
            if len(anchor) != 1:
                raise ValueError(f"Cannot locate unique {item_id} runtime object")
            start = anchor[0].start()
            unit, length = json.JSONDecoder().raw_decode(updated[start:])
            if unit.get("id") != item_id:
                raise ValueError(f"Cannot parse {item_id} runtime object")
            segment = updated[start:start + length]
            star4_object = re.search(r'"star4"\s*:\s*\{([^{}]*)\}', segment)
            if star4_object is None:
                raise ValueError(f"Cannot locate {item_id}.star4")
            if change["field"].startswith("star4."):
                portion = star4_object.group(1)
                offset = star4_object.start(1)
            else:
                portion = segment[star4_object.end():]
                offset = star4_object.end()
            number = r'(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)'
            hits = list(re.finditer(r'"' + re.escape(key) + r'"\s*:\s*' + number, portion))
            if len(hits) != 1 or json.loads(hits[0].group(1)) != change["old"]:
                raise ValueError(f"Cannot safely patch {item_id}.{change['field']}")
            first = start + offset + hits[0].start(1)
            last = start + offset + hits[0].end(1)
            updated = updated[:first] + json.dumps(change["new"]) + updated[last:]
            continue
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
