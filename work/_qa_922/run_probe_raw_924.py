"""跑任意场景并把 **raw stdout+stderr** 落盘。

存在的理由：run_gates.py 只保留含 `CHECK_RESULT` 的行，`SCRIPT ERROR` /
`Parse Error` 全被吃掉 —— 即 false-green 陷阱。这里原样落盘，由调用方 grep。

用法: python run_probe_raw_924.py <res:// 相对场景路径，如 work/_qa_922/x.tscn>
"""
import subprocess, os, sys

EXE = r"C:\Users\WINDOWS\Desktop\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
PROJ = r"C:\Users\WINDOWS\Desktop\GLory-work"
ENV_PATH = r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"

scene = sys.argv[1]
cmd = [EXE, "--headless", "--path", PROJ, scene]
env = dict(os.environ)
env["PATH"] = ENV_PATH
p = subprocess.run(cmd, capture_output=True, timeout=900, env=env, cwd=PROJ)
raw = p.stdout + p.stderr
tag = os.path.basename(scene).replace(".tscn", "")
out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "raw_%s.txt" % tag)
with open(out_path, "wb") as fh:
    fh.write(raw)
print("rc=%s bytes=%d -> %s" % (p.returncode, len(raw), out_path))
