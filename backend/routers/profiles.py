import os
import json
import asyncio
import time
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, ConfigDict

router = APIRouter()
DATA_FILE = "/app/data/profiles.json"


def _load_sync() -> dict:
    if os.path.exists(DATA_FILE):
        try:
            with open(DATA_FILE, "r") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    data.setdefault("profiles", [])
                    data.setdefault("data", {})
                    return data
        except Exception as e:
            print(f"Fout bij laden profiles: {e}")
    return {"profiles": [], "data": {}}


def _save_sync(data: dict):
    try:
        os.makedirs(os.path.dirname(DATA_FILE), exist_ok=True)
        with open(DATA_FILE, "w") as f:
            json.dump(data, f, indent=2)
    except Exception as e:
        print(f"Fout bij opslaan profiles: {e}")


async def load() -> dict:
    return await asyncio.to_thread(_load_sync)


async def save(data: dict):
    await asyncio.to_thread(_save_sync, data)


def _profile_data(data: dict, profile_id: str) -> dict:
    pd = data["data"].setdefault(profile_id, {})
    pd.setdefault("watchlist", [])
    pd.setdefault("progress", {})
    pd.setdefault("ratings", {})
    return pd


class ProfileCreate(BaseModel):
    id: str | None = None
    name: str
    pin: str | None = None
    colorIndex: int = 0
    icon: str | None = None


class ProfileUpdate(BaseModel):
    name: str
    pin: str | None = None
    colorIndex: int = 0
    icon: str | None = None


class WatchlistItem(BaseModel):
    # extra="allow": de Flutter-app slaat het volledige TMDB-item op (incl.
    # velden als "name" voor series i.p.v. "title") en dat moet ongewijzigd
    # rondtrippen in plaats van door pydantic weggefilterd te worden.
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
    rated_at: int | None = None


# --- Profielen ---

@router.get("/")
async def get_profiles():
    data = await load()
    return data["profiles"]


@router.post("/")
async def create_profile(profile: ProfileCreate):
    data = await load()
    new_id = profile.id or str(int(time.time() * 1000))
    entry = {"id": new_id, "name": profile.name, "pin": profile.pin,
             "colorIndex": profile.colorIndex, "icon": profile.icon}
    data["profiles"].append(entry)
    await save(data)
    return entry


@router.put("/{profile_id}")
async def update_profile(profile_id: str, profile: ProfileUpdate):
    data = await load()
    for p in data["profiles"]:
        if p["id"] == profile_id:
            p.update({"name": profile.name, "pin": profile.pin,
                      "colorIndex": profile.colorIndex, "icon": profile.icon})
            await save(data)
            return p
    raise HTTPException(status_code=404, detail="Profiel niet gevonden")


@router.delete("/{profile_id}")
async def delete_profile(profile_id: str):
    data = await load()
    data["profiles"] = [p for p in data["profiles"] if p["id"] != profile_id]
    data["data"].pop(profile_id, None)
    await save(data)
    return {"ok": True}


# --- Watchlist ---

@router.get("/{profile_id}/watchlist")
async def get_watchlist(profile_id: str):
    data = await load()
    return _profile_data(data, profile_id)["watchlist"]


@router.post("/{profile_id}/watchlist")
async def add_to_watchlist(profile_id: str, item: WatchlistItem):
    data = await load()
    pd = _profile_data(data, profile_id)
    if not any(w["id"] == item.id for w in pd["watchlist"]):
        pd["watchlist"].insert(0, item.dict())
        await save(data)
    return {"ok": True}


@router.delete("/{profile_id}/watchlist/{item_id}")
async def remove_from_watchlist(profile_id: str, item_id: int):
    data = await load()
    pd = _profile_data(data, profile_id)
    pd["watchlist"] = [w for w in pd["watchlist"] if w["id"] != item_id]
    await save(data)
    return {"ok": True}


# --- Voortgang ---

@router.get("/{profile_id}/progress")
async def get_all_progress(profile_id: str):
    data = await load()
    return list(_profile_data(data, profile_id)["progress"].values())


@router.post("/{profile_id}/progress")
async def save_progress(profile_id: str, item: ProgressItem):
    data = await load()
    pd = _profile_data(data, profile_id)
    pd["progress"][str(item.id)] = item.dict()
    await save(data)
    return {"ok": True}


@router.delete("/{profile_id}/progress/{item_id}")
async def delete_progress(profile_id: str, item_id: str):
    data = await load()
    pd = _profile_data(data, profile_id)
    pd["progress"].pop(str(item_id), None)
    await save(data)
    return {"ok": True}


# --- Persoonlijke rangschikking (1-3 sterren) ---

@router.get("/{profile_id}/ratings")
async def get_ratings(profile_id: str):
    data = await load()
    return _profile_data(data, profile_id)["ratings"]


@router.post("/{profile_id}/ratings")
async def set_rating(profile_id: str, item: RatingItem):
    data = await load()
    pd = _profile_data(data, profile_id)
    pd["ratings"][str(item.id)] = item.dict()
    await save(data)
    return {"ok": True}


@router.delete("/{profile_id}/ratings/{item_id}")
async def clear_rating(profile_id: str, item_id: int):
    data = await load()
    pd = _profile_data(data, profile_id)
    pd["ratings"].pop(str(item_id), None)
    await save(data)
    return {"ok": True}
