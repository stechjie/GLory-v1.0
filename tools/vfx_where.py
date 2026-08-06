# -*- coding: utf-8 -*-
"""Read a capture and report WHERE each effect landed on the target, in units of
the target's own height.

0% = on the ground at its feet, 100% = the crown of its head, >100% = floating
above it. Uses the screen-space ruler the harness writes into the manifest, so
this is a measurement rather than a guess off a screenshot.
"""
import json
import os
import sys

import numpy as np
from PIL import Image

CAP = sys.argv[1]
man = json.load(open(os.path.join(CAP, 'manifest.json'), encoding='utf-8'))
rulers = man.get('rulers', {})
if not rulers:
    raise SystemExit('this capture has no rulers - re-run the harness')

tgt = rulers['target']
org = rulers['origin']
feet, head = tgt['feet_px'], tgt['head_px']
span = feet - head                      # pixels per unit height
# Only look near the target: the caster is far away down-screen.
band_lo = head - span * 4.0
band_hi = feet + span * 2.0


def ratio(y):
    return (feet - y) / span


print('target=%s  height=%.3f  (%.0f px on screen)' % (
    man.get('target_unit', '?'), tgt['height'], span))
print('%-30s %8s %8s %8s   %s' % ('skill', 'bottom', 'centre', 'top', 'verdict'))

for e in man['skills']:
    f0 = e['first_frame']
    ref = np.asarray(Image.open(os.path.join(CAP, 'frame%08d.png' % (f0 - 1))).convert('RGB')).astype(np.int16)
    best_n, best = 0, None
    for p in range(e['frame_count']):
        cur = np.asarray(Image.open(os.path.join(CAP, 'frame%08d.png' % (f0 + p))).convert('RGB')).astype(np.int16)
        mask = np.abs(cur - ref).max(axis=2) > 12
        mask[:int(max(0, band_lo)), :] = False
        mask[int(min(mask.shape[0], band_hi)):, :] = False
        n = int(mask.sum())
        if n > best_n:
            best_n, best = n, mask
    if best is None or best_n < 40:
        print('%-30s %8s %8s %8s   nothing on the target' % (e['skill_id'], '-', '-', '-'))
        continue
    ys = np.nonzero(best.any(axis=1))[0]
    weights = best.sum(axis=1).astype(float)
    centre = float((np.arange(best.shape[0]) * weights).sum() / weights.sum())
    lo, hi = ratio(float(ys.max())), ratio(float(ys.min()))
    mid = ratio(centre)
    verdict = 'ok (on the body)'
    if mid > 1.35:
        verdict = 'ABOVE THE HEAD'
    elif mid > 1.05:
        verdict = 'at the crown'
    elif mid < -0.15:
        verdict = 'below the feet'
    print('%-30s %7.0f%% %7.0f%% %7.0f%%   %s' % (e['skill_id'], lo * 100, mid * 100, hi * 100, verdict))
