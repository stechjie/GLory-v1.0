"""Trusted administrator Python hotfixes with reversible runtime mutations.

Contract: define apply(ctx), and perform mutations through ctx.replace_attr or
ctx.replace_item. This is an administrator code deployment facility, NOT a
sandbox for player/user code. Imports and custom functions inside apply are
supported. The context owns undo in reverse order, including partial failure.
"""
from __future__ import annotations

import ast
from dataclasses import dataclass
from types import FunctionType


class HotfixRejected(ValueError):
    pass


class MutationContext:
    def __init__(self):
        self._undo = []
        self.closed = False

    def replace_attr(self, target, name: str, value):
        if self.closed:
            raise HotfixRejected("hotfix context is closed")
        if not hasattr(target, name):
            raise HotfixRejected(f"attribute does not exist: {name}")
        original = getattr(target, name)
        self._undo.append(lambda: setattr(target, name, original))
        setattr(target, name, value)

    def replace_item(self, target: dict, key, value):
        if self.closed or not isinstance(target, dict):
            raise HotfixRejected("expected an open context and a dictionary")
        present, original = key in target, target.get(key)
        def undo():
            if present:
                target[key] = original
            else:
                target.pop(key, None)
        self._undo.append(undo)
        target[key] = value

    def revert(self):
        self.closed = True
        failures = []
        for undo in reversed(self._undo):
            try:
                undo()
            except Exception as error:
                failures.append(type(error).__name__)
        self._undo.clear()
        if failures:
            raise RuntimeError("hotfix rollback failed; operator intervention required")


@dataclass(frozen=True)
class PreparedHotfix:
    source: str
    apply: FunctionType


def prepare(source: str) -> PreparedHotfix:
    if not isinstance(source, str) or not 0 < len(source.encode()) <= 128 * 1024:
        raise HotfixRejected("hotfix source must be 1–131072 bytes")
    try:
        tree = ast.parse(source, filename="<admin-hotfix>")
    except SyntaxError as error:
        raise HotfixRejected(f"Python syntax error at line {error.lineno}") from None
    # Validation cannot cause module-level side effects. Put imports and logic
    # inside apply(ctx); disallow decorators/default expressions executed at def.
    if len(tree.body) != 1 or not isinstance(tree.body[0], ast.FunctionDef):
        raise HotfixRejected("source must contain exactly one def apply(ctx)")
    function = tree.body[0]
    args = function.args
    if (function.name != "apply" or function.decorator_list or function.returns or getattr(function, "type_params", [])
            or args.defaults or args.kw_defaults or args.kwonlyargs or args.posonlyargs
            or args.vararg or args.kwarg or len(args.args) != 1 or args.args[0].annotation):
        raise HotfixRejected("use def apply(ctx) without annotations, defaults or decorators")
    # A generator would defer execution beyond the reversible apply transaction.
    if any(isinstance(node, (ast.Yield, ast.YieldFrom, ast.Await)) for node in ast.walk(function)):
        raise HotfixRejected("apply must execute synchronously")
    namespace = {}
    exec(compile(tree, "<admin-hotfix>", "exec"), namespace)
    return PreparedHotfix(source, namespace["apply"])


class PythonHotfixRuntime:
    def __init__(self):
        self.active: list[tuple[str, PreparedHotfix, MutationContext]] = []

    @staticmethod
    def _apply(prepared):
        context = MutationContext()
        try:
            result = prepared.apply(context)
            if result is not None:
                raise HotfixRejected("apply must return None")
        except BaseException:
            context.revert()
            raise
        return context

    def replace(self, sources: list[tuple[str, str]]):
        """Replace the effective ordered set; on failure reinstate the prior set.

        Call under the same coordinator lock as catalogue commits and restores.
        Reverting in reverse order preserves stacked changes to one property.
        """
        if len({key for key, _ in sources}) != len(sources):
            raise HotfixRejected("duplicate hotfix identity")
        prepared = [(key, prepare(source)) for key, source in sources]
        if [(key, patch.source) for key, patch, _ in self.active] == sources:
            return
        previous = [(key, patch) for key, patch, _ in self.active]
        self.clear()
        try:
            for key, patch in prepared:
                context = self._apply(patch)
                self.active.append((key, patch, context))
        except BaseException:
            self.clear()
            for key, patch in previous:
                self.active.append((key, patch, self._apply(patch)))
            raise

    def clear(self):
        for _, _, context in reversed(self.active):
            context.revert()
        self.active.clear()
