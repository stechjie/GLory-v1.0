import json
import unittest

from server_log_audit import analyze


def entry(at, message, *, pid="15", boot="boot-a"):
    return json.dumps({"__REALTIME_TIMESTAMP": str(at * 1000), "MESSAGE": message,
                       "_PID": pid, "_BOOT_ID": boot})


class JournalAuditTests(unittest.TestCase):
    def test_live_server_disconnect_wording(self):
        report = analyze([entry(1000, "[NET] client disconnected peer=99")])
        self.assertEqual(report["server_events"]["peer_disconnected"], 1)

    def test_uploaded_client_history_does_not_count_as_server_freeze(self):
        report = analyze([
            entry(1000, "[NET] clientlog peer=12 | 2026-09-19T20:00:00 | process freeze 30.0s"),
            entry(1010, "[NET] process freeze 6.5s -> heartbeat timers reset"),
        ])
        self.assertEqual(report["server_events"]["process_freeze"], 1)
        self.assertEqual(report["uploaded_client_history_events"]["process_freeze"], 1)
        self.assertEqual(report["server_process_freeze_seconds"]["max"], 6.5)

    def test_interleaved_room_durations_and_pack_time(self):
        report = analyze([
            entry(1000, "server battle simulation started room=1 round=21"),
            entry(1010, "server battle simulation started room=2 round=20"),
            entry(1210, "server replay/result generated room=2 round=20"),
            entry(1420, "server replay/result generated room=1 round=21"),
            entry(1440, "replay packed room=1 round=21 a=100 B b=100 B pack_usec=20000"),
        ])
        self.assertEqual(report["simulation_wall_time_ms"]["count"], 2)
        self.assertEqual(report["simulation_wall_time_ms"]["max"], 420)
        self.assertEqual(report["pack_cpu_time_ms"]["max"], 20)

    def test_restart_is_not_paired_with_previous_process(self):
        report = analyze([
            entry(1000, "server battle simulation started room=1 round=2"),
            entry(5000, "server replay/result generated room=1 round=2", pid="16"),
        ])
        self.assertEqual(report["simulation_wall_time_ms"]["count"], 0)
        self.assertEqual(report["unmatched_simulation_starts"], 1)
        self.assertEqual(report["unmatched_simulation_finishes"], 1)

    def test_cooperative_wall_time_is_distinct_from_compute_and_queue(self):
        report = analyze([
            entry(1000, "server battle simulation started room=1 round=20 queue_wait_ms=3700.5 active=4"),
            entry(1460, "server replay/result generated room=1 round=20 elapsed_ms=4160.5 compute_usec=190000 max_slice_usec=2600 prepare_usec=1400"),
            entry(1470, "server simulation budget overrun elapsed_usec=80000 budget_usec=12000 active=4 queued=16"),
        ])
        self.assertEqual(report["simulation_wall_time_ms"]["max"], 460)
        self.assertEqual(report["simulation_queue_wait_ms"]["max"], 3700.5)
        self.assertEqual(report["simulation_compute_ms"]["max"], 190)
        self.assertEqual(report["simulation_max_slice_ms"]["max"], 2.6)
        self.assertEqual(report["server_events"]["simulation_budget_overrun"], 1)

    def test_no_raw_secrets_or_player_messages_are_exported(self):
        report = analyze([
            entry(1000, "heartbeat timeout peer=99 token=never-export-this -> reconnect"),
            entry(2000, "clientlog peer=99 | private-player-message password=secret"),
            "invalid journal record",
        ])
        output = json.dumps(report)
        self.assertNotIn("never-export-this", output)
        self.assertNotIn("private-player-message", output)
        self.assertEqual(report["malformed_entries"], 1)

    def test_out_of_order_and_missing_data_are_visible(self):
        report = analyze([entry(2000, "server started protocol=32"), entry(1000, "unrelated")])
        self.assertEqual(report["out_of_order_entries"], 1)
        self.assertIsNotNone(report["from_utc"])
        self.assertIsNone(analyze([])["from_utc"])


if __name__ == "__main__":
    unittest.main()
