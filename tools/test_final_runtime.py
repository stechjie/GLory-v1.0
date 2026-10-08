from __future__ import annotations

import copy
import unittest
from pathlib import Path

from openpyxl import load_workbook

from final_runtime import (
    check_business_pages, check_code_rules, check_runtime_files,
    parse_code_rules, parse_runtime_sheet,
)

ROOT = Path(__file__).resolve().parents[1]
BOOK = ROOT / "docs/balance/final status.xlsx"


class FinalRuntimeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.book = load_workbook(BOOK, read_only=True, data_only=True)
        cls.tables = parse_runtime_sheet(cls.book)
        cls.rules = parse_code_rules(cls.book)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.book.close()

    def test_current_sources_match(self) -> None:
        self.assertEqual([], check_runtime_files(ROOT, self.tables))
        self.assertEqual([], check_business_pages(self.book, self.tables))
        self.assertEqual([], check_code_rules(ROOT, self.rules))

    def test_runtime_drift_is_detected(self) -> None:
        changed = copy.deepcopy(self.tables)
        changed["data/shop.json"]["items"][0]["price"] += 1
        self.assertTrue(any("data/shop.json" in e for e in check_runtime_files(ROOT, changed)))

    def test_human_page_drift_is_detected(self) -> None:
        changed = copy.deepcopy(self.tables)
        changed["data/units/race_units.json"]["units"][0]["hp"] += 1
        self.assertTrue(any("01_棋子基础" in e for e in check_business_pages(self.book, changed)))

    def test_shop_page_drift_is_detected(self) -> None:
        changed = copy.deepcopy(self.tables)
        changed["data/shop.json"]["items"][-1]["price"] += 1
        self.assertTrue(any("93_商城目录" in e for e in check_business_pages(self.book, changed)))

    def test_avatar_frame_name_drift_is_detected(self) -> None:
        changed = copy.deepcopy(self.tables)
        changed["data/avatars.json"]["frames"][-1]["name"] = "different"
        self.assertTrue(any("shop_frame_pink_sakura frame name" in e
                            for e in check_business_pages(self.book, changed)))

    def test_code_rule_drift_is_detected(self) -> None:
        changed = copy.deepcopy(self.rules)
        changed["pet_draw.price"]["value"] += 1
        self.assertTrue(any("pet_draw.price" in e for e in check_code_rules(ROOT, changed)))


if __name__ == "__main__":
    unittest.main()
