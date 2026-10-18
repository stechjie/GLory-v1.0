"""Conservative source-dependency pruning in generated stages only.

No source deletion, texture resizing or ABI removal. Unknown dynamic prefixes
retain their entire subtree. Every build emits an auditable exclusion report.
"""
from pathlib import Path
import collections
import json
import re
import subprocess

ART = {'.png', '.jpg', '.jpeg', '.webp', '.svg', '.exr', '.hdr', '.wav', '.mp3', '.ogg',
       '.ttf', '.otf', '.fbx', '.glb', '.gltf', '.tscn', '.tres', '.scn', '.res'}
RESOURCE = {'.tscn', '.tres', '.scn', '.res', '.glb', '.gltf', '.fbx'}
TEXT = {'.gd', '.gdshader', '.json', '.cfg', '.tscn', '.tres', '.csv', '.txt', '.gdextension'}
ROOT_DIRS = {'assets', 'data', 'effects', 'scenes', 'scripts', 'shaders', 'ui', 'patcher', 'addons'}
DEV = ('tools/', 'effects/preview/', 'scenes/debug/', 'patcher/export_plugin/', 'addons/effekseer/')


def closure(files, dependencies, texts, project):
    """Keep runtime source/data, scene roots, and transitive/dynamic dependencies."""
    edges = collections.defaultdict(set)
    dynamic = []
    logical = set(files)
    def reference(owner, value):
        if value.startswith('res://'):
            value = value[6:]
        elif not value.startswith(tuple(x + '/' for x in ROOT_DIRS)):
            return
        if value in logical:
            edges[owner].add(value)
        else:
            # Keep conservative prefixes even for string concatenation (foo + id).
            prefix = re.split(r'%|\{|\*', value, maxsplit=1)[0]
            if not prefix:
                matches = logical
            elif '%' in value or '{' in value or '*' in value:
                matches = {p for p in logical if p.startswith(prefix)}
            else:
                matches = {p for p in logical if p.startswith(value)}
            if matches:
                edges[owner].update(matches)
                dynamic.append({'owner': owner, 'expression': value, 'kept': len(matches)})
    for owner, deps in dependencies.items():
        for dep in deps:
            if 'res://' in dep:
                reference(owner, 'res://' + dep.split('res://', 1)[1])
            elif dep.startswith('uid://'):
                raise RuntimeError('Dependency has no fallback path: ' + dep)
    for owner, text in texts.items():
        # This exact expression classifies model paths; it never loads a directory.
        text = re.sub(r'''\.(?:begins_with|globalize_path)\(\s*["']res://(?:assets/models/)?["']\s*\)''', '', text)
        for value in re.findall(r'''["']([^"'\n]+)["']''', text):
            reference(owner, value)
    roots = {p for p in files if Path(p).suffix in {'.gd', '.gdshader', '.json', '.cfg', '.csv', '.txt', '.gdextension'}}
    roots.update(p for p in files if Path(p).suffix in {'.tscn', '.tres'} and not p.startswith('assets/'))
    roots.update({'project.godot', 'app_icon.png', 'ui/branding/glory_bootstrap.png', 'default_bus_layout.tres'})
    for value in re.findall(r'"\*?(res://[^"\n]+)"', project):
        reference('project.godot', value)
    seen, queue = set(), list(roots)
    while queue:
        node = queue.pop()
        if node in seen:
            continue
        seen.add(node)
        queue.extend(edges[node] - seen)
    return seen, dynamic


def apply(stage, engine, logdir):
    stage, logdir = Path(stage).resolve(), Path(logdir).resolve()
    if (stage / '.git').exists() or not (stage / '.godot/imported').is_dir():
        raise RuntimeError('Slimming requires an imported generated stage, never a Git checkout')
    files = {p.relative_to(stage).as_posix(): p for p in stage.rglob('*')
             if p.is_file() and p.relative_to(stage).parts[0] in ROOT_DIRS and '.godot' not in p.parts}
    files = {n: p for n, p in files.items() if not n.startswith(DEV)
             and not any(x in n for x in ('/Demo_GodotVFX/', '/New folder/', '.bak', '/backups/'))}
    paths = sorted(n for n in files if Path(n).suffix in RESOURCE)
    inputs, output = logdir / 'slim-dependency-input.json', logdir / 'slim-dependencies.json'
    inputs.write_text(json.dumps(paths))
    probe = logdir / 'slim-dependencies.gd'
    probe.write_text('extends SceneTree\nfunc _initialize():\n    var deps = {}\n'
                     '    var paths = JSON.parse_string(FileAccess.get_file_as_string(' + json.dumps(str(inputs)) + '))\n'
                     '    for path in paths:\n        deps[path] = Array(ResourceLoader.get_dependencies("res://" + path))\n'
                     '    FileAccess.open(' + json.dumps(str(output)) + ', FileAccess.WRITE).store_string(JSON.stringify(deps))\n    quit()\n')
    with (logdir / 'slim-dependencies.log').open('w') as log:
        subprocess.run([str(engine), '--headless', '--path', str(stage), '--script', str(probe)],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
    dependencies = json.loads(output.read_text())
    if set(dependencies) != set(paths):
        raise RuntimeError('Incomplete dependency scan; refusing resource exclusions')
    # Inventories list the art library, not assets loaded by the game. Runtime data
    # tables remain roots; external dynamic asset declarations are retained below.
    texts = {n: p.read_text(errors='replace') for n, p in files.items()
             if p.suffix in TEXT and not n.startswith(('assets/', 'data/qa/'))}
    texts.update({n: p.read_text(errors='replace') for n, p in files.items()
                  if n.startswith('assets/') and p.suffix in {'.gd', '.tscn', '.tres', '.gdshader', '.cfg'}})
    manifest = stage / 'assets.manifest.json'
    if manifest.exists():
        declared = json.loads(manifest.read_text()).get('entries', [])
        texts['data/__dynamic_assets__.json'] = json.dumps([x['path'] for x in declared if x.get('class') == 'dynamic_dir'], ensure_ascii=False)
        files['data/__dynamic_assets__.json'] = manifest
    seen, dynamic = closure(files, dependencies, texts, (stage / 'project.godot').read_text())
    removed = sorted(n for n in files if n.startswith('assets/') and Path(n).suffix in ART and n not in seen)
    if any(any(c in n for c in ',\"\n\r') for n in removed):
        raise RuntimeError('Unsafe resource path for Godot exclusion filter')
    cfg = stage / 'export_presets.cfg'
    before = cfg.read_text()
    # All presets share the same game content. Do not remove source files or caches.
    def filters(match):
        values = list(dict.fromkeys(match[1].split(',') + removed))
        return 'exclude_filter=' + json.dumps(','.join(values), ensure_ascii=False)
    after, count = re.subn(r'(?m)^exclude_filter="([^"]*)"', filters, before)
    if not count:
        raise RuntimeError('No export exclusion field; refusing an unfiltered export')
    cfg.write_text(after)
    report = {'policy': 'current-source-dependency-closure-v1', 'removed_source_paths': removed,
              'removed_source_bytes': sum(files[n].stat().st_size for n in removed),
              'reachable_count': len(seen), 'dynamic_keeps': dynamic,
              'source_files_deleted': False, 'texture_quality_changed': False, 'abis_removed': False}
    (logdir / 'slim-resources.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return report
