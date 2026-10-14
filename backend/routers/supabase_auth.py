"""Per-request Supabase client authenticated as the calling user.

The frontend holds the real session (via @supabase/supabase-js) and forwards
its access token as `Authorization: Bearer <token>` on every API call. This
module builds a Postgrest client that uses *that* token directly (not a
service-role key) so the same row-level-security policies the Android app
relies on (`auth.uid() = user_id`, see C:\\Streamio\\supabase\\schema.sql)
apply automatically here too - no separate authorization logic needed on
this side, and a forged/expired token is rejected by Supabase itself, not by
us trying to verify it.
"""
import base64
import json

from fastapi import Header, HTTPException
from supabase import create_client, Client

from . import config_loader


def _decode_user_id(access_token: str) -> str:
    """Reads the `sub` claim out of the JWT payload without verifying the
    signature - fine here because we never use this value to *authorize*
    anything ourselves; it only fills the `user_id` column on inserts, and
    Postgrest's own RLS check (`with check (auth.uid() = user_id)`), which
    verifies the same forwarded token server-side, rejects any insert where
    this doesn't match the token's real subject."""
    try:
        payload_b64 = access_token.split(".")[1]
        padded = payload_b64 + "=" * (-len(payload_b64) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded))
        user_id = payload.get("sub")
        if not user_id:
            raise ValueError("no sub claim")
        return user_id
    except Exception:
        raise HTTPException(status_code=401, detail="Ongeldig sessietoken")


class UserContext:
    def __init__(self, client: Client, user_id: str, access_token: str):
        self.client = client
        self.user_id = user_id
        self.access_token = access_token


def get_user_context(authorization: str | None = Header(default=None)) -> UserContext:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Niet ingelogd")
    access_token = authorization.split(" ", 1)[1].strip()
    if not access_token:
        raise HTTPException(status_code=401, detail="Niet ingelogd")

    supabase_url = config_loader.get_supabase_url()
    supabase_anon_key = config_loader.get_supabase_anon_key()
    if not supabase_url or not supabase_anon_key:
        raise HTTPException(
            status_code=503,
            detail="Supabase is niet geconfigureerd op de server (SUPABASE_URL / SUPABASE_ANON_KEY).",
        )

    client = create_client(supabase_url, supabase_anon_key)
    client.postgrest.auth(access_token)
    user_id = _decode_user_id(access_token)
    return UserContext(client=client, user_id=user_id, access_token=access_token)
