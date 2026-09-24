import subprocess, os, sys, time

EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"

scene = "tools/cold_parse_chain_check.tscn"
cmd = [EXE, "--headless", "--path", PROJ, scene]
env = dict(os.environ)
env["PATH"] = ENV_PATH
t0 = time.time()
p = subprocess.run(cmd, capture_output=True, timeout=360, env=env, cwd=PROJ)
raw = p.stdout + p.stderr
out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cold_parse_924_raw.txt")
with open(out_path, "wb") as fh:
    fh.write(raw)
print("rc=%s dur=%.1fs bytes=%d" % (p.returncode, time.time() - t0, len(raw)))
# Surface SCRIPT ERROR / Parse Error lines
text = raw.decode("utf-8", "replace")
for ln in text.splitlines():
    if any(k in ln for k in ("SCRIPT ERROR", "Parse Error", "ERROR:", "FAIL", "cannot", "Parser Error", "ERROR")):
        print(">>", ln.strip()[:300])
print("WROTE", out_path)
