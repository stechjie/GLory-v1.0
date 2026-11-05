# Game display font (2026-11-05)

The whole game now uses one display font chain, installed by `UIFontFallback.gd`
as the default theme font and engine fallback font:

1. **Knewave** (`Knewave-Regular.ttf`) for Latin letters, digits and punctuation.
   Same file as `assets/fonts/Knewave-Regular.ttf` (the gold-number font), kept here
   so a stale Drive asset bundle cannot remove it.
   - Upstream: https://github.com/google/fonts/tree/main/ofl/knewave
   - SHA-256: `ed3bac761d755b89ab3082c844d4a623d63c7d6eef85d22ba1fb6c680e6a4436`
   - License: SIL OFL 1.1, Reserved Font Name "Knewave"; full text in `Knewave-OFL.txt`.
2. **ZCOOL KuaiLe** (`ZCOOLKuaiLe-Regular.ttf`, 站酷快乐体) for Chinese. Shipped whole
   (7053 glyphs, 1.5 MB) so player names and chat are covered too.
   - Upstream: https://github.com/google/fonts/tree/main/ofl/zcoolkuaile
   - SHA-256: `812a6fc1fe54b6d73a419245c32dfeba8aa33104d5be90d1cf6af082007cb71d`
   - License: SIL OFL 1.1; full text in `ZCOOLKuaiLe-OFL.txt`.
3. **Noto Sans SC** (below) for the few characters KuaiLe lacks.

The RichTextLabel bold / italic variants of the default theme are re-based onto the
same chain, otherwise `[b]中文[/b]` renders as missing-glyph boxes.
`tools/font_fallback_check.gd` checks the chain, idempotent install, and coverage of
every Chinese locale string with system font fallback disabled.

The battle damage counter (`BattleCombatFeedback.gd`) also uses this chain, slightly
narrowed (x0.92) so very large totals stay inside the plate. Libre Baskerville is no
longer used by the game.

# Bundled Chinese UI fallback

`UIFontFallback.gd` runs before the UI and adds Noto Sans SC to Godot's existing
default font fallback chain. The existing Open Sans Latin glyphs, numeric styles,
theme sizes and colours remain in use. The fallback also supplies missing glyphs
to variations of the default font, including RichTextLabel bold and italic.

This font is stored with the UI code so a stale Drive asset bundle cannot remove
it during resource synchronization or build staging. It must remain in source
control with this script.

The script loads the font at runtime (`load`, not `preload`) and does nothing on
the dedicated server (`--server` / `--dedicated-server`). The server package built
by `make_server_zip.ps1` ships scripts only, without `.godot/imported`, so a
preload made the autoload fail to parse there and broke the cold-start smoke
test (2026-09-24). Both export presets use `all_resources`, so the client export
still includes the font.

- Upstream: https://github.com/notofonts/noto-cjk
- File: Sans/SubsetOTF/SC/NotoSansSC-Regular.otf
- Download: https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf
- SHA-256: `faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9`
- License: SIL Open Font License 1.1; full text is in `NotoSansSC-OFL.txt`.

Reproduction and regression check: `tools/font_fallback_check.gd` disables system
font fallback while checking Chinese glyphs in the default theme and all locale
strings. It also checks that Latin text metrics remain unchanged.

The regression check additionally shapes the mixed Chinese/Latin lobby strings
and fullwidth `：（）｜` punctuation in all default theme font variants. It first
removes the bundled fallback to prove that the missing-glyph condition is detected,
then restores it and checks 52 shaped runs with system fallback disabled. This
does not replace screenshot and logcat verification on the target emulator.
