"""Public launch manifest and MFA-admin-only patch upload/publication."""
from contextlib import contextmanager
import hmac
from typing import Annotated, Literal
import zipfile

import httpx
from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field

from app import patch_service, realtime
from app.admin_auth import Admin, current_admin, writing_admin
from app.config import get_settings
from app.patch_firebase import FirebasePublishError
from app.patch_store import PatchConflict

router = APIRouter(tags=["patches"])
Me = Annotated[Admin, Depends(current_admin)]
Writer = Annotated[Admin, Depends(writing_admin)]
Platform = Literal["android", "ios", "windows"]
AutomationPlatform = Literal["android", "ios"]


def service():
    value = patch_service.current()
    if value is None:
        raise HTTPException(503, "补丁服务尚未配置")
    return value


def patch_automation_writer(authorization: str = Header(default="")) -> None:
    """Scoped machine auth for internal Android/iOS patch delivery."""
    expected = get_settings().patch_automation_token
    scheme, _, supplied = authorization.partition(" ")
    if (not expected or scheme.lower() != "bearer" or not supplied
            or not hmac.compare_digest(supplied, expected)):
        raise HTTPException(401, "自动补丁上传凭证无效或未配置")
    return None


PatchAutomationWriter = Annotated[None, Depends(patch_automation_writer)]


def automation_release(release_id: str):
    catalogue = service().store.catalogue()
    release = next((r for r in catalogue["releases"] if r["release_id"] == release_id), None)
    if release is None:
        raise HTTPException(404, "补丁草稿不存在")
    if release["channel"] != "internal" or set(release["platforms"]) != {"android", "ios"}:
        raise HTTPException(403, "自动发布凭证仅允许 iOS、Android 内部测试补丁")
    return catalogue, release


@router.get("/admin/api/patches/automation/{release_id}")
def automation_status(release_id: str, _admin: PatchAutomationWriter):
    catalogue, release = automation_release(release_id)
    return {"revision": catalogue["revision"], "release": release,
            "active": catalogue["active"].get("internal") == release_id}


async def push_snapshots():
    for payload in service().store.client_pushes():
        await realtime.hub().broadcast(payload)


@contextmanager
def failures():
    try:
        yield
    except PatchConflict as error:
        raise HTTPException(409, str(error)) from None
    except (ValueError, zipfile.BadZipFile) as error:
        raise HTTPException(400, str(error)) from None
    except (FirebasePublishError, httpx.HTTPError):
        raise HTTPException(502, "Firebase 上传或回读未成功；当前发布版本未改变") from None
    except OSError:
        raise HTTPException(503, "补丁存储不可用，请检查服务器空间与权限") from None


@router.get("/v1/patches/check")
def check(response: Response, channel: str = Query(max_length=96),
          platform: Platform = Query(), base_id: str = Query(max_length=96),
          installed_seq: int = Query(ge=0)):
    response.headers["Cache-Control"] = "no-store"
    with failures():
        return service().store.snapshot(channel, platform, base_id, installed_seq)


@router.get("/admin/api/patches")
def catalogue(_admin: Me):
    return service().catalogue()


class Draft(BaseModel):
    channel: str = Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$")
    title: str = Field(min_length=1, max_length=200)
    platforms: list[Platform] = Field(min_length=1, max_length=3)


@router.post("/admin/api/patches")
def create(body: Draft, admin: Writer):
    with failures():
        release_id = service().store.create_release(body.channel, body.title, body.platforms, str(admin.auth_uid))
        return {"release_id": release_id}


@router.post("/admin/api/patches/automation/drafts")
def create_automation_draft(body: Draft, _admin: PatchAutomationWriter):
    """Machine credential is limited to internal Android/iOS releases."""
    if body.channel != "internal" or set(body.platforms) != {"android", "ios"}:
        raise HTTPException(400, "自动补丁任务只允许创建包含 iOS、Android 的 internal 草稿")
    with failures():
        existing = next((release for release in service().store.catalogue()["releases"]
                         if release["channel"] == body.channel and release["title"] == body.title
                         and release["status"] == "draft"
                         and sorted(release["platforms"]) == sorted(set(body.platforms))), None)
        if existing:
            return {"release_id": existing["release_id"], "existing": True}
        release_id = service().store.create_release(body.channel, body.title,
                                                     body.platforms, "automated-patch")
        return {"release_id": release_id}


@router.put("/admin/api/patches/{release_id}/artifacts/{platform}")
async def upload(release_id: str, platform: Platform, request: Request, admin: Writer,
                 base_id: str = Query(max_length=96)):
    with failures():
        length = request.headers.get("content-length")
        if length and int(length) > 2_000_000_000:
            raise HTTPException(413, "单个补丁文件不能超过 2 GB")
        return await service().upload(release_id, platform, base_id, request.stream(), str(admin.auth_uid))


@router.put("/admin/api/patches/automation/{release_id}/artifacts/{platform}")
async def upload_automation(release_id: str, platform: AutomationPlatform, request: Request,
                            _admin: PatchAutomationWriter,
                            base_id: str = Query(max_length=96)):
    with failures():
        automation_release(release_id)
        length = request.headers.get("content-length")
        if length and int(length) > 2_000_000_000:
            raise HTTPException(413, "单个补丁文件不能超过 2 GB")
        return await service().upload(release_id, platform, base_id, request.stream(), "automated-patch")


class Publish(BaseModel):
    expected_revision: int = Field(ge=0)


@router.post("/admin/api/patches/automation/{release_id}/publish")
async def publish_automation(release_id: str, body: Publish, _admin: PatchAutomationWriter):
    with failures():
        catalogue, release = automation_release(release_id)
        active_id = catalogue["active"].get("internal")
        active = next((r for r in catalogue["releases"] if r["release_id"] == active_id), None)
        if active and release["seq"] < active["seq"]:
            raise HTTPException(409, "自动发布不能回退到旧补丁")
        changed = await service().publish(release_id, "automated-patch", body.expected_revision)
        revision = service().store.catalogue()["revision"]
    if changed:
        await push_snapshots()
    return {"changed": changed, "revision": revision}


@router.post("/admin/api/patches/{release_id}/publish")
async def publish(release_id: str, body: Publish, admin: Writer):
    with failures():
        changed = await service().publish(release_id, str(admin.auth_uid), body.expected_revision)
        revision = service().store.catalogue()["revision"]
    if changed:
        # A hint is safe across channels; each client fetches its own full snapshot.
        await push_snapshots()
    return {"changed": changed, "revision": revision}


class AccountHotfix(BaseModel):
    channel: str = Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$")
    source: str = Field(min_length=1, max_length=131072)
    expected_revision: int = Field(ge=0)


@router.post("/admin/api/patches/hotfix/account-server")
async def account_hotfix(body: AccountHotfix, admin: Writer):
    with failures():
        key = await service().add_account_hotfix(body.channel, body.source, str(admin.auth_uid), body.expected_revision)
    return {"hotfix_id": key}


@router.post("/admin/api/patches/hotfix/{hotfix_id}/revoke")
async def revoke_hotfix(hotfix_id: str, admin: Writer):
    with failures():
        changed = await service().revoke_hotfix(hotfix_id, str(admin.auth_uid))
        revision = service().store.catalogue()["revision"]
    if changed:
        await push_snapshots()
    return {"changed": changed}


@router.post("/admin/api/patches/hotfix/client")
async def client_hotfix(body: AccountHotfix, admin: Writer):
    with failures():
        key = await service().add_client_hotfix(body.channel, body.source, str(admin.auth_uid), body.expected_revision)
        revision = service().store.catalogue()["revision"]
    await push_snapshots()
    return {"hotfix_id": key}


@router.post("/admin/api/patches/hotfix/battle-server")
async def battle_hotfix(body: AccountHotfix, admin: Writer):
    with failures():
        key = await service().add_battle_hotfix(body.channel, body.source, str(admin.auth_uid), body.expected_revision)
    return {"hotfix_id": key, "state": "pending_battle_ack"}
