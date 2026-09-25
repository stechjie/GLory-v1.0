#!/usr/bin/env python3
"""Summarize journalctl -o json without exporting raw player messages or secrets.

Input must be ordered oldest first. Client-uploaded history is counted separately:
its journal timestamp is upload time, not the time when that client froze.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import math
import re
import sys

PATTERNS = {
    "simulation_started": r"server battle simulation started\b",
    "simulation_generated": r"server replay/result generated\b",
    "replay_packed": r"replay packed\b",
    "replay_retry": r"replay retry\b",
    "replay_give_up": r"replay give up\b",
    "replay_delivered": r"replay delivery complete\b",
    "replay_rejected": r"replay (?:unpack|split|chunk).*?(?:reject|abort|fail)",
    "replay_delivery_failed": r"replay (?:delivery|receive) failed\b",
    "simulation_budget_overrun": r"server simulation budget overrun\b",
    "result_ack_timeout": r"result ack timeout\b",
    "tls_handshake_error": r"TLS handshake error:",
    "engine_error": r"\bERROR:",
    "process_freeze": r"process freeze\b",
    "heartbeat_timeout": r"heartbeat timeout\b",
    "pong_silence": r"pong silence\b",
    "peer_disconnected": r"(?:peer|client) disconnected\b",
    "resume": r"(?:resume (?:ok|accepted|success)|resumed seat|resume_completed)",
    "server_started": r"server started protocol=",
    "script_error": r"SCRIPT ERROR:",
    "oom": r"(?:Out of memory:|oom-kill|Killed process .*godot)",
    "app_backgrounded": r"app paused\b",
}
COMPILED = {name: re.compile(pattern, re.I) for name, pattern in PATTERNS.items()}
NUMERIC_FIELDS = re.compile(
    r"\b(room|round|peer|slot|protocol|epoch|port|frames|tries|try|pack_usec|"
    r"replay_a_raw|replay_a_zstd|replay_b_zstd|ser_usec|declared|cap|"
    r"compute_usec|max_slice_usec|prepare_usec|elapsed_usec|budget_usec|active|queued)=(\d+)\b"
)
DECIMAL_FIELDS = re.compile(r"\b(queue_wait_ms|elapsed_ms)=([0-9]+(?:\.[0-9]+)?)\b")


def iso_time(microseconds: int) -> str:
    return datetime.fromtimestamp(microseconds / 1_000_000, timezone.utc).isoformat()


def distribution(values: list[float]) -> dict:
    if not values:
        return {"count": 0}
    ordered = sorted(values)
    def percentile(p: float) -> float:
        return round(ordered[max(0, math.ceil(len(ordered) * p) - 1)], 3)
    return {"count": len(values), "p50": percentile(.5), "p95": percentile(.95),
            "p99": percentile(.99), "max": round(ordered[-1], 3)}


def analyze(lines, *, example_limit: int = 60) -> dict:
    counts = Counter()
    client_counts = Counter()
    starts = {}
    simulation_ms = []
    simulations = []
    pack_ms = []
    queue_wait_ms = []
    compute_ms = []
    simulation_slice_ms = []
    freezes = []
    examples = []
    malformed = 0
    entries = 0
    first = None
    last = None
    out_of_order = 0
    unmatched_finishes = 0
    superseded_starts = 0
    for line in lines:
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            timestamp = int(row["__REALTIME_TIMESTAMP"])
            message = row.get("MESSAGE", "")
            if not isinstance(message, str):
                raise ValueError("non-text journal message")
        except (ValueError, TypeError, KeyError):
            malformed += 1
            continue
        entries += 1
        if last is not None and timestamp < last:
            out_of_order += 1
        first = timestamp if first is None else min(first, timestamp)
        last = timestamp if last is None else max(last, timestamp)
        is_client = bool(re.search(r"\bclientlog peer=\d+\s*\|", message))
        categories = [name for name, pattern in COMPILED.items() if pattern.search(message)]
        target_counts = client_counts if is_client else counts
        target_counts.update(categories)
        if is_client:
            # Never pair server work with uploaded client history, or use upload
            # time as a client incident time. No raw client history in output.
            continue
        fields = {key: int(value) for key, value in NUMERIC_FIELDS.findall(message)}
        fields.update({key: float(value) for key, value in DECIMAL_FIELDS.findall(message)})
        # A PID and boot identity prevent a restart reusing room/round numbers
        # from producing a fictitious hours-long battle.
        key = (row.get("_BOOT_ID"), row.get("_PID"), fields.get("room"), fields.get("round"))
        if "simulation_started" in categories and fields.get("room") is not None:
            if "queue_wait_ms" in fields:
                queue_wait_ms.append(fields["queue_wait_ms"])
            if key in starts:
                superseded_starts += 1
            starts[key] = timestamp
        if "simulation_generated" in categories:
            if "compute_usec" in fields:
                compute_ms.append(fields["compute_usec"] / 1000)
            if "max_slice_usec" in fields:
                simulation_slice_ms.append(fields["max_slice_usec"] / 1000)
            started = starts.pop(key, None)
            if started is None or timestamp < started:
                unmatched_finishes += 1
            else:
                elapsed = (timestamp - started) / 1000
                simulation_ms.append(elapsed)
                simulations.append({"started_at": iso_time(started), "finished_at": iso_time(timestamp),
                                    "elapsed_ms": round(elapsed, 3), "room": fields.get("room"),
                                    "round": fields.get("round")})
        if "replay_packed" in categories and "pack_usec" in fields:
            pack_ms.append(fields["pack_usec"] / 1000)
        freeze = re.search(r"process freeze ([0-9.]+)s", message)
        if freeze:
            freezes.append(float(freeze[1]))
        noteworthy = set(categories) - {"simulation_started", "simulation_generated", "replay_packed"}
        if noteworthy:
            examples.append({"observed_at": iso_time(timestamp), "events": sorted(noteworthy),
                             **fields, **({"freeze_seconds": float(freeze[1])} if freeze else {})})
            if len(examples) > example_limit:
                examples.pop(0)
    return {
        "journal_entries": entries, "malformed_entries": malformed,
        "out_of_order_entries": out_of_order,
        "from_utc": iso_time(first) if first is not None else None,
        "to_utc": iso_time(last) if last is not None else None,
        "server_events": dict(sorted(counts.items())),
        "uploaded_client_history_events": dict(sorted(client_counts.items())),
        "simulation_wall_time_ms": distribution(simulation_ms),
        "simulation_queue_wait_ms": distribution(queue_wait_ms),
        "simulation_compute_ms": distribution(compute_ms),
        "simulation_max_slice_ms": distribution(simulation_slice_ms),
        "pack_cpu_time_ms": distribution(pack_ms),
        "server_process_freeze_seconds": distribution(freezes),
        "slowest_simulations": sorted(simulations, key=lambda x: x["elapsed_ms"], reverse=True)[:20],
        "unmatched_simulation_starts": len(starts),
        "unmatched_simulation_finishes": unmatched_finishes,
        "superseded_simulation_starts": superseded_starts,
        "recent_noteworthy_server_events": examples,
        "limitations": [
            "No matching log is not proof of no failure; verify journal retention and release logging.",
            "Client history counts use upload time, not client incident time, and cannot establish causality.",
            "Simulation wall time includes scheduling and, with cooperative jobs, time between slices.",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("journal", nargs="?", default="-", help="journalctl JSON lines, or - for stdin")
    args = parser.parse_args()
    if args.journal == "-":
        result = analyze(sys.stdin)
    else:
        with open(args.journal, encoding="utf-8") as stream:
            result = analyze(stream)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
