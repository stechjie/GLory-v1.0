"""Durable single-login generation; refresh/reconnect never take ownership."""
from __future__ import annotations

import uuid
import asyncio
from fastapi import HTTPException
from app import db

HEADER = "X-Glory-Session"
ownership_lock = asyncio.Lock()


async def require_refresh(session_id: uuid.UUID) -> None:
    if not await db.pool().fetchval(
        "SELECT EXISTS(SELECT 1 FROM public.login_sessions WHERE session_id=$1)", session_id):
        raise rejected()


def rejected() -> HTTPException:
    # Distinct from an expired Supabase token: never silently retry/register.
    return HTTPException(409, detail="session_replaced")


async def require(auth_uid: str, session_id: str | None) -> None:
    try:
        sid = uuid.UUID(session_id or "")
    except ValueError:
        raise rejected() from None
    active = await db.pool().fetchval(
        "SELECT session_id FROM public.login_sessions WHERE auth_uid=$1", uuid.UUID(auth_uid))
    if active != sid:
        raise rejected()


async def issue(auth_uid: str) -> str:
    sid = uuid.uuid4()
    await db.pool().execute(
        "INSERT INTO public.login_sessions(auth_uid, session_id) VALUES($1,$2) "
        "ON CONFLICT(auth_uid) DO UPDATE SET session_id=EXCLUDED.session_id, connected_at=now()",
        uuid.UUID(auth_uid), sid)
    return str(sid)


async def release(auth_uid: str, session_id: str) -> None:
    # A delayed logout from A cannot delete B's newer login.
    await db.pool().execute(
        "DELETE FROM public.login_sessions WHERE auth_uid=$1 AND session_id=$2",
        uuid.UUID(auth_uid), uuid.UUID(session_id))
