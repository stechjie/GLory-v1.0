-- One durable login generation per authenticated account. Socket presence is
-- separate: a mobile disconnect must not revoke the reconnect credential.
CREATE TABLE IF NOT EXISTS public.login_sessions (
    auth_uid uuid PRIMARY KEY,
    session_id uuid NOT NULL,
    connected_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.login_sessions ENABLE ROW LEVEL SECURITY;
CREATE UNIQUE INDEX IF NOT EXISTS login_sessions_session_id_idx ON public.login_sessions(session_id);
REVOKE ALL ON public.login_sessions FROM anon, authenticated;
