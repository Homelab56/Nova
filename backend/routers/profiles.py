"""Profiles, watchlist, watch progress and ratings - backed by the same
Supabase project and tables the Streamify Android TV app syncs through (see
C:\\Streamio\\supabase\\schema.sql), so a profile created here, or watch
progress saved here, shows up on the TV and vice versa.

Every endpoint requires a signed-in user (get_user_context) and talks to
Postgrest using *that user's own* forwarded token, so RLS enforces
ownership - we still filter by profile_id/user_id explicitly for clarity,
but a mismatched profile_id simply returns nothing rather than someone
else's data.
"""
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict

from .supabase_auth import UserContext, get_user_context

router = APIRouter()

PROFILES_TABLE = "profiles"
LIBRARY_TABLE = "library_items"
PROGRESS_TABLE = "watch_progress"
RATINGS_TABLE = "ratings"


def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class ProfileCreate(BaseModel):
    name: str
    avatar_color_hex: str = "#1E88E5"
    avatar_id: str | None = None
    is_admin: bool = False


class ProfileUpdate(BaseModel):
    name: str
    avatar_color_hex: str = "#1E88E5"
    avatar_id: str | None = None


class WatchlistItem(BaseModel):
    # extra="allow": sla het volledige TMDB-item op zodat de kaart in de UI
    # meteen alles heeft (poster, overview, ...) zonder een tweede fetch.
    model_config = ConfigDict(extra="allow")
    id: int
    title: str = ""
    poster_path: str = ""
    backdrop_path: str = ""
    media_type: str = "movie"
    release_date: str = ""
    first_air_date: str = ""
    vote_average: float = 0.0
    overview: str = ""


class ProgressItem(BaseModel):
    model_config = ConfigDict(extra="allow")
    id: int | str
    title: str = ""
    poster_path: str = ""
    backdrop_path: str = ""
    media_type: str = "movie"
    release_date: str = ""
    first_air_date: str = ""
    vote_average: float = 0.0
    current_time: float = 0.0
    duration: float = 0.0
    show_id: int | None = None
    season_number: int | None = None
    episode_number: int | None = None


class RatingItem(BaseModel):
    model_config = ConfigDict(extra="allow")
    id: int
    stars: int
    media_type: str = "movie"
    title: str = ""
    poster_path: str = ""
    backdrop_path: str = ""


# --- Profielen ---

@router.get("/")
async def get_profiles(ctx: UserContext = Depends(get_user_context)):
    res = (
        ctx.client.table(PROFILES_TABLE)
        .select("*")
        .eq("user_id", ctx.user_id)
        .is_("deleted_at", "null")
        .order("is_admin", desc=True)
        .order("updated_at")
        .execute()
    )
    return res.data


@router.post("/")
async def create_profile(profile: ProfileCreate, ctx: UserContext = Depends(get_user_context)):
    row = {
        "id": str(uuid.uuid4()),
        "user_id": ctx.user_id,
        "name": profile.name,
        "avatar_color_hex": profile.avatar_color_hex,
        "avatar_id": profile.avatar_id,
        "is_admin": profile.is_admin,
    }
    res = ctx.client.table(PROFILES_TABLE).insert(row).execute()
    if not res.data:
        raise HTTPException(status_code=500, detail="Profiel aanmaken mislukt")
    return res.data[0]


@router.put("/{profile_id}")
async def update_profile(profile_id: str, profile: ProfileUpdate, ctx: UserContext = Depends(get_user_context)):
    res = (
        ctx.client.table(PROFILES_TABLE)
        .update({
            "name": profile.name,
            "avatar_color_hex": profile.avatar_color_hex,
            "avatar_id": profile.avatar_id,
            "updated_at": _iso_now(),
        })
        .eq("id", profile_id)
        .eq("user_id", ctx.user_id)
        .execute()
    )
    if not res.data:
        raise HTTPException(status_code=404, detail="Profiel niet gevonden")
    return res.data[0]


@router.delete("/{profile_id}")
async def delete_profile(profile_id: str, ctx: UserContext = Depends(get_user_context)):
    ctx.client.table(PROFILES_TABLE).update({"deleted_at": _iso_now()}).eq("id", profile_id).eq(
        "user_id", ctx.user_id
    ).execute()
    return {"ok": True}


# --- Watchlist (library_items) ---

@router.get("/{profile_id}/watchlist")
async def get_watchlist(profile_id: str, ctx: UserContext = Depends(get_user_context)):
    res = (
        ctx.client.table(LIBRARY_TABLE)
        .select("*")
        .eq("profile_id", profile_id)
        .eq("user_id", ctx.user_id)
        .is_("deleted_at", "null")
        .order("added_at", desc=True)
        .execute()
    )
    return [_library_row_to_item(r) for r in res.data]


@router.post("/{profile_id}/watchlist")
async def add_to_watchlist(profile_id: str, item: WatchlistItem, ctx: UserContext = Depends(get_user_context)):
    row = {
        "user_id": ctx.user_id,
        "profile_id": profile_id,
        "content_id": str(item.id),
        "content_type": item.media_type,
        "name": item.title or "",
        "poster": item.poster_path or None,
        "background": item.backdrop_path or None,
        "description": item.overview or None,
        "release_info": item.release_date or item.first_air_date or None,
        "imdb_rating": item.vote_average or None,
        "added_at": _iso_now(),
    }
    ctx.client.table(LIBRARY_TABLE).upsert(
        row, on_conflict="profile_id,content_id,content_type"
    ).execute()
    return {"ok": True}


@router.delete("/{profile_id}/watchlist/{item_id}")
async def remove_from_watchlist(profile_id: str, item_id: int, ctx: UserContext = Depends(get_user_context)):
    ctx.client.table(LIBRARY_TABLE).update({"deleted_at": _iso_now()}).eq("profile_id", profile_id).eq(
        "user_id", ctx.user_id
    ).eq("content_id", str(item_id)).execute()
    return {"ok": True}


def _library_row_to_item(row: dict) -> dict:
    return {
        "id": int(row["content_id"]) if str(row["content_id"]).isdigit() else row["content_id"],
        "title": row.get("name") or "",
        "poster_path": row.get("poster") or "",
        "backdrop_path": row.get("background") or "",
        "media_type": row.get("content_type") or "movie",
        "release_date": row.get("release_info") or "",
        "first_air_date": row.get("release_info") or "",
        "vote_average": row.get("imdb_rating") or 0.0,
        "overview": row.get("description") or "",
    }


# --- Voortgang (watch_progress) ---

@router.get("/{profile_id}/progress")
async def get_all_progress(profile_id: str, ctx: UserContext = Depends(get_user_context)):
    res = (
        ctx.client.table(PROGRESS_TABLE)
        .select("*")
        .eq("profile_id", profile_id)
        .eq("user_id", ctx.user_id)
        .is_("deleted_at", "null")
        .execute()
    )
    return [_progress_row_to_item(r) for r in res.data]


@router.post("/{profile_id}/progress")
async def save_progress(profile_id: str, item: ProgressItem, ctx: UserContext = Depends(get_user_context)):
    season = item.season_number if item.season_number is not None else -1
    episode = item.episode_number if item.episode_number is not None else -1
    # The Android app only ever writes "movie"/"tv" to content_type (season/episode columns
    # are what distinguish a specific episode) - Nova's own "tv_episode" is a frontend-only
    # distinction that must not leak into the shared column, or the two apps' rows for the
    # same episode would never match on (profile_id, content_id, season, episode).
    content_type = "tv" if item.media_type == "tv_episode" else item.media_type
    row = {
        "user_id": ctx.user_id,
        "profile_id": profile_id,
        "content_id": str(item.show_id or item.id),
        "content_type": content_type,
        "season": season,
        "episode": episode,
        "name": item.title or "",
        "poster": item.poster_path or None,
        "backdrop": item.backdrop_path or None,
        "position_ms": int(item.current_time * 1000),
        "duration_ms": int(item.duration * 1000),
        "progress_percent": (item.current_time / item.duration) if item.duration > 0 else None,
        "source": "web",
        "last_watched_at": _iso_now(),
    }
    ctx.client.table(PROGRESS_TABLE).upsert(
        row, on_conflict="profile_id,content_id,season,episode"
    ).execute()
    return {"ok": True}


@router.delete("/{profile_id}/progress/{item_id}")
async def delete_progress(profile_id: str, item_id: str, ctx: UserContext = Depends(get_user_context)):
    # item_id matches the synthetic id _progress_row_to_item builds: either the
    # bare content_id (movie) or "tv:{content_id}:{season}:{episode}" (episode).
    query = ctx.client.table(PROGRESS_TABLE).update({"deleted_at": _iso_now()}).eq(
        "profile_id", profile_id
    ).eq("user_id", ctx.user_id)
    parts = item_id.split(":")
    if len(parts) == 4 and parts[0] == "tv":
        query = query.eq("content_id", parts[1]).eq("season", int(parts[2])).eq("episode", int(parts[3]))
    else:
        query = query.eq("content_id", item_id)
    query.execute()
    return {"ok": True}


def _progress_row_to_item(row: dict) -> dict:
    season = row.get("season", -1)
    episode = row.get("episode", -1)
    is_episode = season is not None and season >= 0
    synthetic_id = (
        f"tv:{row['content_id']}:{season}:{episode}" if is_episode else row["content_id"]
    )
    # Mirror back Nova's own "tv_episode" distinction (see save_progress) so the frontend's
    # existing media_type === "tv_episode" filters keep working, even though the shared
    # column only ever holds "movie"/"tv".
    media_type = "tv_episode" if is_episode else (row.get("content_type") or "movie")
    return {
        "id": synthetic_id,
        "title": row.get("name") or "",
        "poster_path": row.get("poster") or "",
        "backdrop_path": row.get("backdrop") or "",
        "media_type": media_type,
        "current_time": (row.get("position_ms") or 0) / 1000.0,
        "duration": (row.get("duration_ms") or 0) / 1000.0,
        "show_id": int(row["content_id"]) if is_episode and str(row["content_id"]).isdigit() else None,
        "season_number": season if is_episode else None,
        "episode_number": episode if is_episode else None,
    }


# --- Persoonlijke rangschikking (1-3 sterren) ---

@router.get("/{profile_id}/ratings")
async def get_ratings(profile_id: str, ctx: UserContext = Depends(get_user_context)):
    res = (
        ctx.client.table(RATINGS_TABLE)
        .select("*")
        .eq("profile_id", profile_id)
        .eq("user_id", ctx.user_id)
        .is_("deleted_at", "null")
        .execute()
    )
    return {str(r["tmdb_id"]): {"id": r["tmdb_id"], "stars": r["stars"], "media_type": r["media_type"]} for r in res.data}


@router.post("/{profile_id}/ratings")
async def set_rating(profile_id: str, item: RatingItem, ctx: UserContext = Depends(get_user_context)):
    row = {
        "user_id": ctx.user_id,
        "profile_id": profile_id,
        "tmdb_id": item.id,
        "media_type": item.media_type,
        "stars": item.stars,
        "rated_at": _iso_now(),
    }
    ctx.client.table(RATINGS_TABLE).upsert(row, on_conflict="profile_id,tmdb_id,media_type").execute()
    return {"ok": True}


@router.delete("/{profile_id}/ratings/{item_id}")
async def clear_rating(profile_id: str, item_id: int, ctx: UserContext = Depends(get_user_context)):
    ctx.client.table(RATINGS_TABLE).update({"deleted_at": _iso_now()}).eq("profile_id", profile_id).eq(
        "user_id", ctx.user_id
    ).eq("tmdb_id", item_id).execute()
    return {"ok": True}
