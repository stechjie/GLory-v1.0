# Code, resources and package boundaries

- Source: `stechjie/GLory-v1.0`, branch `codex/battle-server-stability` (not yet merged into main). Start Godot from `project.godot`; runtime code is in `scripts/`, scenes in `scenes/`, UI in `ui/`, game data in `data/`.
- Resources: [shared Drive folder](https://drive.google.com/drive/u/0/folders/1qDvPXP6VaB2DaIcJb_yg5P9xjbP-NKRc). Use the existing `Glory-art-assets-full-20260914.zip` baseline plus `Glory-resources-incremental-20260925-9f690075.zip`. The incremental archive is not a standalone full resource set. Follow its manifest, including removal entries. Do not overwrite current code with the old Drive project tree.
- Tests and maintenance tools belong in Git under `tools/`; documentation belongs under `docs/`. Neither belongs in the runtime package.
- Existing local packaging wrappers are outside this repository: `/Volumes/repository/github/GLory/tools/glory_build.py` and `glory_ios_build.py`. This change does not publish those machine-specific release tools. Other machines can use the repository export template and `tools/android_smoke.sh`, with their own signing setup.

## Export policy

Commit `export_presets.template.cfg`, never the private `export_presets.cfg` or signing credentials. The template and local presets now exclude review output, authoring sources, documentation and credentials. `.gdignore` also prevents preview textures in `review_visual_20260912/`, `Claude outputs/`, `art_source/` and device evidence from being imported. Runtime scripts, scenes and materials have no direct references into those three authoring/review directories.

Historical source/evidence files are retained; this is not a destructive repository cleanup. `all_resources` includes unreferenced resources, so every new development directory needs an export exclusion or `.gdignore`. Runtime `.godot/imported` textures must not be indiscriminately deleted.

`scripts/qa/` remains intentionally packaged because DeviceHarness depends on it. A future production/QA split must change the entry point and scene references together.

## Post-export check

```sh
python3 tools/package_content_check.py /absolute/path/game.apk
python3 tools/package_content_check.py /absolute/path/game.ipa
```

The checker rejects known development directories in APK resources or an IPA's Godot PCK v4 index. Unsupported pack formats fail closed. QA files are listed separately. This is a content-boundary check, not a comprehensive security scan. Run it after each export before publishing.

2026-09-26 validation: the existing a8930aa9 APK fails with 13 development paths; a real Godot 4.7 export of an isolated fixture using the new filters passes, retains runtime/QA scenes, and excludes the development fixtures. No complete APK or IPA was rebuilt for this change. TestFlight 0.0.6 (12) remains unchanged.

Resource verification: all 3,441 resource payload files match the previous delivery manifest, with zero changed/removed files and zero merge conflicts. Reuse the existing resource archive rather than upload a duplicate full archive.
