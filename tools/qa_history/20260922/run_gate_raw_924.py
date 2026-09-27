import subprocess, os, sys, time

EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"

name = sys.argv[1]
scene = "tools/%s.tscn" % name
cmd = [EXE, "--headless", "--path", PROJ, scene]
env = dict(os.environ)
env["PATH"] = ENV_PATH
p = subprocess.run(cmd, capture_output=True, timeout=360, env=env, cwd=PROJ)
raw = p.stdout + p.stderr
out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "raw_%s.txt" % name)
with open(out_path, "wb") as fh:
    fh.write(raw)
print("rc=%s bytes=%d -> %s" % (p.returncode, len(raw), out_path))
