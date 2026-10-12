import unittest
from unittest.mock import patch
import glory_patch_nightly as nightly

class MachinePublishTests(unittest.TestCase):
    def test_already_active_does_not_republish(self):
        status = {"active": True, "release": {"status": "published"}, "revision": 7}
        with patch.object(nightly, "api", return_value=status) as api:
            nightly.publish_release("fixture", "token")
            self.assertEqual([c.args[0] for c in api.call_args_list], ["GET", "GET"])

    def test_publishes_exact_observed_revision_and_confirms(self):
        with patch.object(nightly, "api", side_effect=[{"active": False, "revision": 9}, {}, {"active": True, "release": {"status": "published"}}]) as api:
            nightly.publish_release("fixture", "token")
            self.assertEqual(api.call_args_list[1].args[-1], {"expected_revision": 9})

    def test_failed_confirmation_is_not_success(self):
        with patch.object(nightly, "api", side_effect=[{"active": False, "revision": 9}, {}, {"active": False}]), self.assertRaises(RuntimeError):
            nightly.publish_release("fixture", "token")

if __name__ == "__main__":
    unittest.main()
