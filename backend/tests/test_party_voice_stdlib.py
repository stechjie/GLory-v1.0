"""Pure token checks; run without installing backend packages."""

import base64
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app import party_voice  # noqa: E402


class VoiceTokenTests(unittest.TestCase):
    def test_token_is_party_scoped_and_microphone_only(self):
        cfg = {"api_key": "key", "api_secret": "s" * 48, "client_url": "wss://voice.example"}
        issued = party_voice.issue(cfg, "abc", "v1", "ABCD1234", "Player", 1000)
        segment = issued["token"].split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4)))
        self.assertEqual(claims["sub"], "ABCD1234")
        self.assertEqual(claims["video"]["room"], "party-abc-v1")
        self.assertEqual(claims["video"]["canPublishSources"], ["microphone"])
        self.assertFalse(claims["video"]["canPublishData"])
        self.assertNotIn("roomAdmin", claims["video"])
        self.assertNotIn("roomCreate", claims["video"])

    def test_membership_epoch_changes_room(self):
        self.assertNotEqual(party_voice.room_name("abc", "old"),
                            party_voice.room_name("abc", "new"))


if __name__ == "__main__":
    unittest.main()
