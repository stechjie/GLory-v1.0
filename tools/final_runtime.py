"""Validate the combat-focused final workbook against runtime JSON and code."""
from __future__ import annotations

import json
from pathlib import Path

from final_excel_owned import godot_round, percent

FILES = (
    "data/rounds/round_schedule.json",
    "data/units/race_units.json",
    "data/pve/pve_monsters.json",
    "data/boss/bosses.json",
    "data/mercenary/mercenaries.json",
    "data/treasure/treasures.json",
    "data/formation/formation_allies.json",
    "data/pets/pets.json",
    "data/codex/treasure_text.json",
)


def first_difference(left, right, pointer="$"):
    if type(left) is not type(right):
        return pointer, left, right
    if isinstance(left, dict):
        if left.keys() != right.keys():
            return pointer + "/keys", list(left), list(right)
        for key in left:
            diff = first_difference(left[key], right[key], pointer + "/" + str(key))
            if diff:
                return diff
    elif isinstance(left, list):
        if len(left) != len(right):
            return pointer + "/length", len(left), len(right)
        for index, (a, b) in enumerate(zip(left, right)):
            diff = first_difference(a, b, pointer + "/" + str(index))
            if diff:
                return diff
    elif left != right:
        return pointer, left, right
    return None


def check_runtime_files(root: Path, tables: dict[str, object]) -> list[str]:
    errors = []
    for relative in FILES:
        path = root / relative
        try:
            current = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(f"{relative}: cannot load: {exc}")
            continue
        diff = first_difference(tables[relative], current)
        if diff:
            pointer, expected, actual = diff
            errors.append(f"{relative} {pointer}: final={expected!r}, runtime={actual!r}")
    return errors

def check_business_pages(workbook, tables: dict[str, object]) -> list[str]:
    """Check the readable final pages against the typed runtime sheet."""
    errors = []

    def expect(label, actual, expected):
        if actual != expected:
            errors.append(f"{label}: final={actual!r}, runtime={expected!r}")

    def rows(name):
        for row in workbook[name].iter_rows(min_row=4, values_only=True):
            if row and row[0] not in (None, ""):
                yield row

    def index(file, collection):
        result = {}
        for item in tables[file][collection]:
            item_id = item["id"]
            if item_id in result:
                errors.append(f"{file}: duplicate id {item_id}")
            result[item_id] = item
        return result

    units = index("data/units/race_units.json", "units")
    unit_rows = list(rows("01_棋子基础"))
    expect("01_棋子基础 count", len(unit_rows), len(units))
    for row in unit_rows:
        unit_id = str(row[0])
        if unit_id not in units:
            errors.append(f"01_棋子基础: unknown id {unit_id}")
            continue
        item = units[unit_id]
        for col, key in [(1, "name"), (4, "tier"), (5, "cost"), (6, "hp"),
                         (10, "atk"), (14, "def"), (28, "skill_id")]:
            expect(f"01_棋子基础 {unit_id} {key}", row[col], item.get(key))

    monsters = index("data/pve/pve_monsters.json", "monsters")
    monster_rows = list(rows("05_野怪"))
    expect("05_野怪 count", len(monster_rows), len(monsters))
    for row in monster_rows:
        item = monsters.get(str(row[0]))
        if item is None:
            errors.append(f"05_野怪: unknown id {row[0]}")
            continue
        for col, key in [(1, "name"), (4, "hp"), (5, "atk"), (6, "def"),
                         (7, "attack_speed"), (13, "skill_id")]:
            expect(f"05_野怪 {row[0]} {key}", row[col], item.get(key))

    bosses = index("data/boss/bosses.json", "bosses")
    boss_rows = list(rows("06_Boss"))
    expect("06_Boss count", len(boss_rows), len(bosses))
    for row in boss_rows:
        item = bosses.get(str(row[0]))
        if item is None:
            errors.append(f"06_Boss: unknown id {row[0]}")
            continue
        for col, key in [(1, "name"), (18, "attack_speed"), (23, "skill_id")]:
            expect(f"06_Boss {row[0]} {key}", row[col], item.get(key))
        for col, key in [(3, "hp"), (4, "atk"), (14, "def")]:
            expect(f"06_Boss {row[0]} first_spawn_{key}", row[col],
                   godot_round(item[key] * 1.5))

    mercs = index("data/mercenary/mercenaries.json", "mercenaries")
    merc_rows = list(rows("07_佣兵"))
    expect("07_佣兵 count", len(merc_rows), len(mercs))
    for row in merc_rows:
        item = mercs.get(str(row[0]))
        if item is None:
            errors.append(f"07_佣兵: unknown id {row[0]}")
            continue
        for col, key in [(1, "name"), (2, "carrot_cost"), (3, "cost"),
                         (5, "hp"), (6, "atk"), (7, "def"),
                         (8, "attack_speed"), (17, "skill_id")]:
            expect(f"07_佣兵 {row[0]} {key}", row[col], item.get(key))

    pets_table = tables["data/pets/pets.json"]
    pets = {item["id"]: item for item in pets_table["pets"]}
    pet_rows = list(rows("03_宠物技能"))
    expect("03_宠物技能 count", len(pet_rows), len(pets))
    for row in pet_rows:
        pet_id = str(row[0])
        item = pets.get(pet_id)
        if item is None:
            errors.append(f"03_宠物技能: unknown pet {pet_id}")
            continue
        expect(f"pet {pet_id} name", row[1], item["name"])
        expect(f"pet {pet_id} English", row[2], item["name_en"])
        expect(f"pet {pet_id} value", percent(row[4], f"pet {pet_id} value")[0], item["value"])
        expect(f"pet {pet_id} starter", row[7] == "是", pet_id in pets_table["starter_ids"])

    treasure_rows = [r for r in rows("09_宝藏与套装") if len(r) > 7 and r[7] == "已审定"]
    treasures = index("data/treasure/treasures.json", "treasures")
    expect("09_宝藏与套装 count", len(treasure_rows), len(treasures))
    for row in treasure_rows:
        item = treasures.get(str(row[0]))
        if item is None:
            errors.append(f"09_宝藏与套装: unknown id {row[0]}")
        else:
            expect(f"treasure {row[0]} name", row[1], item["name"])
    links = index("data/treasure/treasures.json", "linkages")
    link_rows = [r for r in rows("10_宝藏联动") if len(r) > 8 and r[8] == "已审定"]
    expect("10_宝藏联动 count", len(link_rows), len(links))
    for row in link_rows:
        if str(row[0]) not in links:
            errors.append(f"10_宝藏联动: unknown id {row[0]}")

    rounds = tables["data/rounds/round_schedule.json"]
    round_rows = [r for r in rows("13_怪物Boss回合") if isinstance(r[0], int)]
    expect("13_怪物Boss回合 count", len(round_rows), rounds["final_round"])
    for row in round_rows:
        number = row[0]
        kind = ("final" if number == rounds["final_round"] else
                "boss" if number in rounds["boss_rounds"] else
                "pvp" if number in rounds["pvp_rounds"] else "pve")
        expect(f"round {number} type", row[1], kind)
        expect(f"round {number} treasure", row[2] == "是",
               number in rounds["treasure_after_battle_rounds"])
    return errors

CODE_RULE_PATTERNS = {
    "treasure.phoenix_revive_hp_rate": (
        "scripts/battle/BattleSimTreasures.gd",
        [r"victim\.max_hp\)\s*\*\s*([0-9.]+)\)",
         r'(?s)if bool\(f\.get\("phoenix_used".*?f\.max_hp\)\s*\*\s*([0-9.]+)\)']),
    "synergy.undead_poison_antiheal": (
        "scripts/units/SynergyService.gd",
        [r'"undead_poison_antiheal":\s*([0-9.]+)\s+if']),
}


def parse_code_rules(workbook) -> dict[str, dict]:
    rules = {}
    for number, row in enumerate(workbook["92_战斗参数"].iter_rows(min_row=4, values_only=True), 4):
        if not row or row[0] in (None, ""):
            continue
        rule_id, value, kind, path, expression = row[:5]
        if rule_id in rules or rule_id not in CODE_RULE_PATTERNS:
            raise ValueError(f"92_战斗参数 row {number}: unknown or duplicate ID {rule_id!r}")
        if kind not in ("int", "float") or (kind == "int" and type(value) is not int) or (
            kind == "float" and type(value) not in (float, int)
        ):
            raise ValueError(f"92_战斗参数 row {number}: invalid {kind!r} value {value!r}")
        if path != CODE_RULE_PATTERNS[rule_id][0]:
            raise ValueError(f"92_战斗参数 row {number}: code location changed unexpectedly")
        rules[rule_id] = {"value": value, "type": kind, "path": path,
                          "expression": expression}
    if set(rules) != set(CODE_RULE_PATTERNS):
        raise ValueError(f"92_战斗参数 IDs mismatch: {sorted(set(rules) ^ set(CODE_RULE_PATTERNS))}")
    return rules


def check_code_rules(root: Path, rules: dict[str, dict]) -> list[str]:
    import re

    errors = []
    for rule_id, rule in rules.items():
        path, patterns = CODE_RULE_PATTERNS[rule_id]
        try:
            source = (root / path).read_text(encoding="utf-8-sig")
        except OSError as exc:
            errors.append(f"{rule_id}: cannot read {path}: {exc}")
            continue
        for pattern in patterns:
            matches = re.findall(pattern, source)
            if len(matches) != 1:
                errors.append(f"{rule_id}: expected one code expression in {path}, got {len(matches)}")
                continue
            actual = int(matches[0]) if rule["type"] == "int" else float(matches[0])
            expected = rule["value"]
            if actual != expected:
                errors.append(f"{rule_id}: final={expected!r}, code={actual!r} in {path}")
    return errors
