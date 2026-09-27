#!/usr/bin/env python3
# Decode user's grass/snow footstep MP3, find the cleanest single footstep,
# and write a soft, short, mono lobby-pet footstep WAV.
import os, sys, json, math
import numpy as np
import miniaudio

SRC = r"C:/Users/WINDOWS/Desktop/音效｜草地雪地脚步声｜音频.mp3"
OUT = r"C:/Users/WINDOWS/Desktop/GLory-work/assets/audio/sfx/lobby/pet_footstep.wav"
ANALYSIS = r"C:/Users/WINDOWS/Desktop/GLory-work/tools/qa_history/20260922/footstep_analysis.txt"
SR = 44100

# 1) Decode to mono float32 @ 44100.
# miniaudio's dr_libs MP3 backend fails on the ID3v2.4 tag in this file, so
# strip the tag and decode the raw frames from memory instead.
raw = open(SRC, "rb").read()
off = 0
if raw[:3] == b"ID3":
    sz = ((raw[6] & 0x7F) << 21) | ((raw[7] & 0x7F) << 14) | ((raw[8] & 0x7F) << 7) | (raw[9] & 0x7F)
    off = 10 + sz
d = miniaudio.decode(raw[off:], output_format=miniaudio.SampleFormat.FLOAT32,
                    nchannels=1, sample_rate=SR)
x = np.asarray(d.samples, dtype=np.float32)
if x.ndim > 1:
    x = x.reshape(-1)
n = x.shape[0]
dur = n / SR
log = []
log.append(f"decoded: n={n} sr={d.sample_rate} channels={d.nchannels} duration={dur:.3f}s")

# 2) Envelope (RMS in 5ms windows)
win = int(0.005 * SR)
if win < 1:
    win = 1
# frame the signal
nframe = n // win
env = np.empty(nframe, dtype=np.float64)
for i in range(nframe):
    seg = x[i*win:(i+1)*win].astype(np.float64)
    env[i] = math.sqrt(np.mean(seg*seg) + 1e-12)
peak = float(env.max())
log.append(f"frames={nframe} rms_peak={peak:.4f}")

# 3) Find the dominant footstep as the global amplitude peak (the impact),
#    then verify it sits on a clear attack->decay shape with quiet surroundings.
peak_idx = int(np.argmax(np.abs(x)))
peak_t = peak_idx / SR
log.append(f"global amplitude peak at sample {peak_idx} t={peak_t:.3f}s")

# count how many distinct impact regions exist (secondary peaks well separated
# from the main one) so we know if the clip holds one step or several.
thr = 0.35 * peak
min_gap = int(0.08 * SR / win)  # frames
cands = []
for i in range(1, nframe-1):
    if env[i] >= thr and env[i] >= env[i-1] and env[i] >= env[i+1]:
        if not cands or (i - cands[-1]) >= min_gap:
            cands.append(i)
log.append(f"distinct impact regions (>=0.35*peak, >=80ms apart): {len(cands)}")

# 4) Extract a 0.18s window: 0.03s attack lead before the impact + 0.15s body/decay.
seg_len = int(0.18 * SR)
start = peak_idx - int(0.03 * SR)
end = start + seg_len
if start < 0:
    # shift right if there isn't enough lead; keep window inside the signal
    start = 0
    end = min(n, seg_len)
end = min(n, end)
seg = x[start:end].astype(np.float64)
log.append(f"segment window samples [{start},{end}] ({seg.shape[0]/SR:.3f}s)")
# normalize if too quiet
mx = float(np.max(np.abs(seg))) + 1e-9
seg = seg / mx
log.append(f"raw seg: len={seg.shape[0]} ({seg.shape[0]/SR:.3f}s) pre_norm_absmax={mx:.4f}")

# 6) Gentle 2nd-order low-pass @ ~7kHz to remove any MP3/high-freq harshness
def biquad_lp(sig, sr, cutoff, q=0.707):
    w0 = 2*math.pi*cutoff/sr
    alpha = math.sin(w0)/(2*q)
    cw = math.cos(w0)
    b0 = (1-cw)/2; b1 = 1-cw; b2 = (1-cw)/2
    a0 = 1+alpha; a1 = -2*cw; a2 = 1-alpha
    b0/=a0; b1/=a0; b2/=a0; a1/=a0; a2/=a0
    y = np.zeros_like(sig)
    x1=x2=y1=y2=0.0
    for i in range(sig.shape[0]):
        xi = sig[i]
        yi = b0*xi + b1*x1 + b2*x2 - a1*y1 - a2*y2
        y[i] = yi
        x2=x1; x1=xi; y2=y1; y1=yi
    return y

seg = biquad_lp(seg, SR, 7000.0, q=0.707)
seg = biquad_lp(seg, SR, 7000.0, q=0.707)  # 2x for a smoother slope

# 7) Soft fade in/out (5ms) to avoid clicks
fade = int(0.005 * SR)
if fade > 0 and seg.shape[0] > 2*fade:
    fi = np.linspace(0, 1, fade)
    fo = np.linspace(1, 0, fade)
    seg[:fade] *= fi
    seg[-fade:] *= fo

# 8) Normalize to soft target peak 0.5
seg = seg / (float(np.max(np.abs(seg))) + 1e-9) * 0.5

# 9) Write 16-bit PCM mono WAV
pcm = np.clip(seg, -1.0, 1.0)
pcm16 = (pcm * 32767.0).astype(np.int16)
import wave
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with wave.open(OUT, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(pcm16.tobytes())
log.append(f"WROTE {OUT} samples={pcm16.shape[0]} ({pcm16.shape[0]/SR:.3f}s) peak={float(np.max(np.abs(seg))):.3f}")

# verification: per-10ms RMS envelope of the final segment (attack->decay check)
vw = int(0.010 * SR)
env10 = []
for i in range(0, seg.shape[0], vw):
    blk = seg[i:i+vw]
    env10.append(float(np.sqrt(np.mean(blk*blk)) + 1e-12))
bars = " ".join(f"{v:04.2f}" for v in env10)
log.append(f"final 10ms-RMS envelope ({len(env10)} steps): {bars}")

with open(ANALYSIS, "w", encoding="utf-8") as f:
    f.write("\n".join(log) + "\n")
print("\n".join(log))
