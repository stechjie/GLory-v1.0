"""Explicit GitHub + Drive update entry point; never reset or stash user work."""
import argparse
import json
from pathlib import Path
import subprocess
import glory_build as b


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--workers', type=int, choices=range(1, 17), default=12)
    p.add_argument('--git-only', action='store_true')
    args = p.parse_args()
    with b.file_lock(b.ROOT / 'build/.source-update.lock', nonblocking=True):
        result = b.sync_project(b.ROOT / 'GLory-v1.0')
        if not args.git_only:
            subprocess.run(['bash', str(Path(__file__).with_name('sync_res.sh')),
                            '--workers', str(args.workers)], check=True)
        print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
