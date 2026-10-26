from contextlib import asynccontextmanager
from unittest.mock import AsyncMock
from app import login_sessions, matchmaking, service_control


def isolate_http_services(monkeypatch, app):
    @asynccontextmanager
    async def lifespan(_app):
        yield
    monkeypatch.setattr(app.router, "lifespan_context", lifespan)
    monkeypatch.setattr(login_sessions, "require", AsyncMock(return_value=None))
    monkeypatch.setattr(service_control, "read", AsyncMock(return_value=service_control.ABSENT))
    monkeypatch.setattr(service_control, "record_entry", AsyncMock(return_value=None))
    monkeypatch.setattr(matchmaking, "_instance", matchmaking.Matchmaker(AsyncMock(return_value=1)))
