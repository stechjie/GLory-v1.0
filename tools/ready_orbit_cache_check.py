#!/usr/bin/env python3
"""Prepare retained legacy/cached fixtures and verify ReadyOrbit's exact draw stream.

Use --render to additionally render identical fixed phases with the GLES desktop
backend and compare captured pixels. No phone or game-state operations are used.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess

PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_GODOT = PROJECT.parent / 'glory-ios-dev/tools/godot/Godot.app/Contents/MacOS/Godot'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', type=Path, default=DEFAULT_GODOT)
    parser.add_argument('--out', type=Path, default=PROJECT.parent/'output/perf_20261113_live/asset_audit/ready_orbit')
    parser.add_argument('--render', action='store_true')
    args = parser.parse_args()
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=True)
    baseline = (PROJECT/'tools/fixtures/ready_orbit_glow_legacy.gd.txt').read_text()
    cached = (PROJECT/'scenes/prep/effects/ReadyOrbitGlow.gd').read_text()
    asset_candidates = [PROJECT/'assets/ui/buttons/ready_loading_rune.png', PROJECT.parent/'res/assets/ui/buttons/ready_loading_rune.png']
    rune = next((p for p in asset_candidates if p.is_file()), None)
    if rune is None:
        raise SystemExit('The unchanged ready_loading_rune.png source is required for visual fixtures.')
    # Some workspace assets only live in the merge input. Load the same PNG in
    # both fixtures without importing/copying it into the source checkout.
    source_preload = 'const MAGIC_RING := preload("res://assets/ui/buttons/ready_loading_rune.png")'
    image_load = 'var MAGIC_RING := ImageTexture.create_from_image(Image.load_from_file(' + json.dumps(str(rune)) + '))'
    for name, original in [('baseline', baseline), ('cached', cached)]:
        source = original.replace(source_preload, image_load)
        if source == original:
            raise SystemExit('Expected rune preload declaration was not found; update fixture preparation explicitly.')
        if name == 'cached':
            source = source.replace('_cached_size = size\n', '_cached_size = size\n\t_test_geometry_rebuilds += 1\n')
            source = source.replace('_cached_phase = _phase\n', '_cached_phase = _phase\n\t_test_color_rebuilds += 1\n')
            source += '\nvar _test_geometry_rebuilds := 0\nvar _test_color_rebuilds := 0\n'
        (out/f'{name}_recording.gd').write_text(source.replace('layer.draw_', 'layer.capture_'))
        (out/f'{name}_lifecycle.gd').write_text(source.replace('if is_instance_valid(_rear):', 'if is_instance_valid(_rear):\n\t\t_test_redraw_batches += 1')+'\nvar _test_redraw_batches := 0\n')
    (out/'fixture_manifest.json').write_text(json.dumps({'baseline_sha256':hashlib.sha256(baseline.encode()).hexdigest(),'cached_sha256':hashlib.sha256(cached.encode()).hexdigest(),'rune_source':str(rune),'rune_sha256':hashlib.sha256(rune.read_bytes()).hexdigest(),'fixture_substitution':'Same unchanged PNG loaded via ImageTexture on both sides; draw calls intercepted only for argument-stream check.'},indent=2))
    commands = [('ready_orbit_cache_check', ['--headless','--max-fps','120','--script','res://tools/ready_orbit_cache_check.gd'])]
    if args.render:
        commands.append(('ready_orbit_pixel_check',['--rendering-method','gl_compatibility','--rendering-driver','opengl3_angle','--audio-driver','Dummy','--windowed','--resolution','400x240','--script','res://tools/ready_orbit_capture_check.gd']))
    for name, options in commands:
        command=[str(args.godot), '--path', str(PROJECT), *options, '--', '--fixture-dir', str(out)]
        with (out/f'{name}.log').open('w') as log:
            result=subprocess.run(command,cwd=PROJECT,stdout=log,stderr=subprocess.STDOUT,timeout=90)
        if result.returncode:
            raise SystemExit(f'{name} failed ({result.returncode}); inspect {out/name}.log')
        print(name, 'PASS')

if __name__ == '__main__':
    main()
