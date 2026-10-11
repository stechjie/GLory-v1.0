import sys
import types
import unittest

from app.patch_runtime import HotfixRejected, PythonHotfixRuntime, prepare


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.module = types.ModuleType("glory_hotfix_test_fixture")
        self.module.boss = {"hp": 100}
        self.module.reward = lambda: 2
        sys.modules[self.module.__name__] = self.module
        self.addCleanup(sys.modules.pop, self.module.__name__)
        self.runtime = PythonHotfixRuntime()
        self.addCleanup(self.runtime.clear)

    def source(self, body):
        return "def apply(ctx):\n import glory_hotfix_test_fixture as game\n " + body.replace("\n", "\n ") + "\n"

    def test_live_function_and_boss_data_revert_on_clear(self):
        source = self.source('ctx.replace_item(game.boss, "hp", 80)\nctx.replace_attr(game, "reward", lambda: 5)')
        self.runtime.replace([("fix", source)])
        self.assertEqual(self.module.boss["hp"], 80)
        self.assertEqual(self.module.reward(), 5)
        self.runtime.clear()
        self.assertEqual(self.module.boss["hp"], 100)
        self.assertEqual(self.module.reward(), 2)

    def test_failed_new_code_restores_prior_effective_fix(self):
        old = self.source('ctx.replace_item(game.boss, "hp", 90)')
        self.runtime.replace([("old", old)])
        bad = self.source('ctx.replace_item(game.boss, "hp", 1)\nraise ValueError("failure")')
        with self.assertRaises(ValueError):
            self.runtime.replace([("bad", bad)])
        self.assertEqual(self.module.boss["hp"], 90)
        self.assertEqual([key for key, _, _ in self.runtime.active], ["old"])

    def test_stacked_fixes_removed_in_reverse_order(self):
        first = self.source('ctx.replace_item(game.boss, "hp", 90)')
        second = self.source('ctx.replace_item(game.boss, "hp", 70)')
        self.runtime.replace([("first", first), ("second", second)])
        self.runtime.replace([("first", first)])
        self.assertEqual(self.module.boss["hp"], 90)
        self.runtime.replace([])
        self.assertEqual(self.module.boss["hp"], 100)

    def test_validation_cannot_execute_module_level_side_effect(self):
        for source in ('raise Exception("side effect")', 'def apply(ctx=print("bad")):\n pass',
                       '@print("bad")\ndef apply(ctx):\n pass', 'def apply(ctx):\n yield 1'):
            with self.subTest(source=source), self.assertRaises(HotfixRejected):
                prepare(source)


if __name__ == "__main__":
    unittest.main()
