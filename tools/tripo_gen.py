"""Tripo 3D 生成工具：图片 -> 模型（GLB），并下载 Tripo 渲染的预览图。

key 从环境变量 TRIPO_API_KEY 或 %USERPROFILE%/.tripo/api_key 读取，不写进仓库。

用法：
  python tools/tripo_gen.py image <输入图.png> <输出目录> [--pbr] [--quad] [--face-limit N]
  python tools/tripo_gen.py balance
"""
import argparse
import json
import mimetypes
import os
import sys
import time
import urllib.request
import uuid

API = "https://api.tripo3d.ai/v2/openapi"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) tripo-gen/1.0"


def load_key():
    key = os.environ.get("TRIPO_API_KEY")
    if not key:
        path = os.path.join(os.path.expanduser("~"), ".tripo", "api_key")
        with open(path, encoding="utf-8") as f:
            key = f.read().strip()
    return key


def _req(method, path, key, body=None, headers=None, timeout=120):
    # Cloudflare 会拦 urllib 默认 UA（error 1010），统一带一个通用 UA
    h = {"Authorization": f"Bearer {key}", "User-Agent": UA}
    if headers:
        h.update(headers)
    if isinstance(body, dict):
        body = json.dumps(body).encode("utf-8")
        h["Content-Type"] = "application/json"
    r = urllib.request.Request(API + path, data=body, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise SystemExit(f"HTTP {e.code} {path}: {e.read().decode('utf-8', 'replace')}")
    if data.get("code") != 0:
        raise SystemExit(f"Tripo 错误 {path}: {data}")
    return data["data"]


def upload(key, file_path):
    boundary = uuid.uuid4().hex
    name = os.path.basename(file_path)
    ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
    with open(file_path, "rb") as f:
        content = f.read()
    body = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\n"
        f"Content-Type: {ctype}\r\n\r\n"
    ).encode("utf-8") + content + f"\r\n--{boundary}--\r\n".encode("utf-8")
    data = _req("POST", "/upload", key, body,
                {"Content-Type": f"multipart/form-data; boundary={boundary}"})
    return data["image_token"]


def wait_task(key, task_id, poll=5, timeout=1200):
    start = time.time()
    last = None
    while True:
        d = _req("GET", f"/task/{task_id}", key)
        status = d.get("status")
        prog = d.get("progress")
        if (status, prog) != last:
            print(f"  [{int(time.time() - start)}s] {status} {prog}%", flush=True)
            last = (status, prog)
        if status == "success":
            return d
        if status in ("failed", "cancelled", "banned", "expired", "unknown"):
            raise SystemExit(f"任务失败: {json.dumps(d, ensure_ascii=False)}")
        if time.time() - start > timeout:
            raise SystemExit("等待超时")
        time.sleep(poll)


def download(url, dest):
    r = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(r, timeout=300) as resp, open(dest, "wb") as f:
        f.write(resp.read())
    print(f"  已下载 {dest} ({os.path.getsize(dest) // 1024} KB)")


def save_outputs(task, out_dir, prefix):
    out = task.get("output", {})
    saved = {}
    for field, ext in (("pbr_model", ".glb"), ("model", ".glb"), ("base_model", ".glb"),
                       ("rendered_image", ".webp")):
        url = out.get(field)
        if not url:
            continue
        if field in ("model", "base_model") and "pbr_model" in saved:
            continue
        guess = os.path.splitext(url.split("?")[0])[1] or ext
        dest = os.path.join(out_dir, f"{prefix}_{field}{guess}")
        download(url, dest)
        saved[field] = dest
    return saved


def cmd_image(args):
    key = load_key()
    os.makedirs(args.out_dir, exist_ok=True)
    print("上传图片…")
    token = upload(key, args.image)
    ext = os.path.splitext(args.image)[1].lstrip(".").lower().replace("jpeg", "jpg")
    body = {
        "type": "image_to_model",
        "file": {"type": ext, "file_token": token},
        "texture": True,
        "pbr": args.pbr,
        "texture_quality": "detailed",
        "texture_alignment": "original_image",
        "auto_size": True,
        "orientation": "align_image",
    }
    if args.model_version:
        body["model_version"] = args.model_version
    if args.face_limit:
        body["face_limit"] = args.face_limit
    if args.quad:
        body["quad"] = True
    print("创建任务…", json.dumps({k: v for k, v in body.items() if k != "file"}, ensure_ascii=False))
    task_id = _req("POST", "/task", key, body)["task_id"]
    print("task_id:", task_id)
    task = wait_task(key, task_id)
    saved = save_outputs(task, args.out_dir, "model")
    meta = {"task_id": task_id, "request": body, "saved": saved,
            "consumed_credit": task.get("consumed_credit")}
    with open(os.path.join(args.out_dir, "tripo_task.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    print("完成:", json.dumps(meta, ensure_ascii=False))
    print("余额:", _req("GET", "/user/balance", key))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("balance")
    pi = sub.add_parser("image")
    pi.add_argument("image")
    pi.add_argument("out_dir")
    pi.add_argument("--pbr", action="store_true", help="生成 PBR 材质（卡通风一般不要）")
    pi.add_argument("--quad", action="store_true")
    pi.add_argument("--face-limit", type=int)
    pi.add_argument("--model-version")
    args = p.parse_args()
    if args.cmd == "balance":
        print(_req("GET", "/user/balance", load_key()))
    else:
        cmd_image(args)


if __name__ == "__main__":
    sys.exit(main())
