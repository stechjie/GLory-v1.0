"""Same-host atomic file protocol between the account and Godot battle processes.

Paths are operator configuration, never administrator-provided request paths.
The account process owns the desired file; the battle service owns the status
file. OS ownership is the trust boundary. No public code execution endpoint.
"""
import hashlib
import json
import os
from pathlib import Path
import time


class BattleBridge:
    def __init__(self, desired: Path, status: Path, instance_id: str):
        self.desired, self.status = Path(desired), Path(status)
        self.instance_id = instance_id
        self.latest = None

    def tick(self, service, now=None):
        now = time.time() if now is None else now
        try:
            if self.status.stat().st_size > 32768:
                return False
            status = json.loads(self.status.read_text())
            if (status.get("instance_id") != self.instance_id or status.get("protocol") != 1
                    or abs(now - float(status.get("heartbeat", 0))) > 15):
                self.latest = None
                return False
            deployment = status["deployment_id"]
            if not isinstance(deployment, str) or len(deployment) != 64 or any(c not in "0123456789abcdef" for c in deployment):
                return False
        except (OSError, ValueError, KeyError, TypeError):
            self.latest = None
            return False
        changed = service.store.observe_battle_deployment(self.instance_id, deployment)
        if changed:
            service.restore_runtime()  # Drops expired account-side effects too.
        catalogue = service.store.catalogue()
        items = [{"hotfix_id": key, "source": source, "sha256": hashlib.sha256(source.encode()).hexdigest()}
                 for key, source in service.store.effective_sources("battle_server")]
        payload = {"protocol": 1, "instance_id": self.instance_id, "battle_deployment_id": deployment,
                   "deployment_id": catalogue["deployment_id"], "hotfix_epoch": catalogue["hotfix_epoch"],
                   "revision": catalogue["revision"], "generated_at": now, "hotfixes": items}
        self.desired.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.desired.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        os.replace(temporary, self.desired)
        self.latest = {"instance_id": self.instance_id, "deployment_id": deployment,
                       "applied_revision": status.get("applied_revision", -1),
                       "required_revision": catalogue["revision"], "error": status.get("error", ""),
                       "heartbeat": status["heartbeat"]}
        return changed
