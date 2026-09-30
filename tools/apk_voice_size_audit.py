"""Verify the actual APK: declared JNI methods, ARM-only libraries and no QA payload.

Usage: python tools/apk_voice_size_audit.py game.apk --report audit.json
Uses only Python's standard library; does not execute code from the APK.
"""
import argparse
import json
import struct
import zipfile
from pathlib import Path

REQUIRED = {"hasRecordPermission", "joinRoom", "leaveRoom", "setMicrophoneEnabled",
            "setParticipantVolume", "setAudience", "getStatus", "getCapabilities"}
CLASS = "Lcom/glory/voice/GloryVoicePlugin;"
ARTIFACT_ROOTS = {"work", "reports", "captures", "logs", "docs", "art_source",
                  "backend", "database", "deploy", "delivery", "tools", "officetest",
                  "Claude outputs", "generated-images"}


def declared_voice_methods(data):
    """Read encoded class methods, not incidental strings elsewhere in a DEX."""
    if not data.startswith(b"dex\n"):
        raise ValueError("Unsupported DEX format")
    def u32(offset):
        return struct.unpack_from("<I", data, offset)[0]
    def uleb(offset):
        value = 0
        for shift in range(0, 35, 7):
            byte = data[offset]
            offset += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value, offset
        raise ValueError("Invalid ULEB128")
    strings = []
    for i in range(u32(56)):
        offset = u32(u32(60) + 4 * i)
        _, offset = uleb(offset)
        strings.append(data[offset:data.index(b"\0", offset)].decode("utf-8", errors="replace"))
    types = [strings[u32(u32(68) + 4 * i)] for i in range(u32(64))]
    found = set()
    for i in range(u32(96)):
        definition = u32(100) + 32 * i
        if types[u32(definition)] != CLASS:
            continue
        offset = u32(definition + 24)
        if not offset:
            continue
        counts = []
        for _ in range(4):
            count, offset = uleb(offset)
            counts.append(count)
        for _ in range(counts[0] + counts[1]):
            _, offset = uleb(offset)
            _, offset = uleb(offset)
        for count in counts[2:]:
            method_index = 0
            for _ in range(count):
                delta, offset = uleb(offset)
                method_index += delta
                _, offset = uleb(offset)
                _, offset = uleb(offset)
                found.add(strings[u32(u32(92) + 8 * method_index + 4)])
    return found


def audit(path):
    methods, failures, sizes = set(), [], {}
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        for info in archive.infolist():
            name = info.filename
            if name.endswith(".dex") and "/" not in name:
                methods.update(declared_voice_methods(archive.read(info)))
            parts = name.split("/")
            group = "/".join(parts[:2])
            sizes[group] = sizes.get(group, 0) + info.compress_size
            if name.startswith("assets/") and len(parts) > 2:
                root = parts[1]
                if root in ARTIFACT_ROOTS or root.startswith(("_qa_", "A4_", "A5_", "B4_", "B5_", "D3_", "D4_", "D5_", "D6_", "E3_", "review_")):
                    failures.append("development_payload:" + name)
        abis = sorted({n.split("/")[1] for n in names if n.startswith("lib/") and n.endswith(".so")})
        if not abis or set(abis) - {"arm64-v8a", "armeabi-v7a"}:
            failures.append("unexpected_abis:" + ",".join(abis))
        for method in sorted(REQUIRED - methods):
            failures.append("missing_declared_voice_method:" + method)
        for abi in abis:
            if not any(n.startswith("lib/" + abi + "/") and "lkjingle" in n for n in names):
                failures.append("missing_webrtc_library:" + abi)
    return {"passed": not failures, "failures": failures, "apk_bytes": path.stat().st_size,
            "abis": abis, "declared_required_voice_methods": sorted(methods & REQUIRED),
            "compressed_groups": dict(sorted(sizes.items(), key=lambda item: -item[1]))}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    report = audit(args.apk)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print("APK_VOICE_SIZE_AUDIT", "PASS" if report["passed"] else "FAIL",
          "bytes=", report["apk_bytes"], "failures=", len(report["failures"]))
    raise SystemExit(0 if report["passed"] else 1)
