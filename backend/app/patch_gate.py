"""Authoritative admission check for cooperative clients, not binary attestation."""
from app.config import get_settings
from app import patch_service


def problem(headers):
    config = get_settings()
    if not config.patch_enforce_versions:
        return None
    service = patch_service.current()
    if service is None:
        return {"status": 503, "code": "patch_unavailable", "detail": "更新服务暂不可用，请稍后重试"}
    failure = {"status": 426, "code": "patch_required", "detail": "游戏版本已更新，请重新启动并完成更新"}
    channel = headers.get("x-glory-patch-channel", "")
    if channel != config.patch_gameplay_channel:
        return failure
    try:
        sequence = headers.get("x-glory-patch-seq", "")
        if not sequence.isascii() or not sequence.isdecimal() or len(sequence) > 18:
            return failure
        snapshot = service.store.snapshot(channel, headers.get("x-glory-patch-platform", ""),
            headers.get("x-glory-patch-base", ""), int(sequence))
    except ValueError:
        return failure
    if snapshot["action"] != "none":
        return failure
    return None
