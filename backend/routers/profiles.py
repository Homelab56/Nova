import os
import json
import asyncio
import shutil
import time
from datetime import datetime, timezone
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, ConfigDict

router = APIRouter()
DATA_FILE = "/app/data/profiles.json"
BACKUP_DIR = "/app/data/profiles_backups"
MAX_BACKUPS = 20

# Alle endpoints hieronder doen een read-modify-write op hetzelfde gedeelde
# bestand. Zonder lock kunnen twee gelijktijdige requests (bv. een profiel
# aanmaken op de ene TV terwijl een andere net kijkvoortgang opslaat) elkaars
# wijziging overschrijven - de langzaamste "wint" en herschrijft het bestand
# met zijn eigen, inmiddels verouderde snapshot, wat stilzwijgend andere
# profielen kan wissen. Eén lock per proces (uvicorn draait hier single-
# worker) sluit die race volledig uit.
_lock = asyncio.Lock()


def _load_sync() -> dict:
    if not os.path.exists(DATA_FILE):
        return {"profiles": [], "data": {}}
    with open(DATA_FILE, "r") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("profiles.json bevat geen object")
    data.setdefault("profiles", [])
    data.setdefault("data", {})
    return data


def _save_sync(data: dict):
    # Atomisch schrijven (tmp + rename i.p.v. in-place overschrijven): een
    # afgebroken write (crash, container-kill) kan zo nooit een half
    # geschreven/corrupt bestand achterlaten dat een latere read stil zou
    # doen terugvallen op "geen profielen".
    os.makedirs(os.path.dirname(DATA_FILE), exist_ok=True)
    tmp_path = f"{DATA_FILE}.tmp"
    with open(tmp_path, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp_path, DATA_FILE)


async def load() -> dict:
    try:
        return await asyncio.to_thread(_load_sync)
    except Exception as e:
        # Een kapot/onleesbaar bestand stil vervangen door "geen profielen"
        # zou een volgende save() dat lege resultaat blijvend laten
        # overschrijven - liever de request laten falen dan data verliezen.
        print(f"Fout bij laden profiles: {e}")
        raise HTTPException(status_code=503, detail="Profielgegevens tijdelijk niet leesbaar, probeer opnieuw.")


async def save(data: dict):
    await asyncio.to_thread(_save_sync, data)


def _backup_sync():
    """Kopieert het huidige bestand weg vóór een wijziging aan de profielen-
    lijst zelf (aanmaken/bewerken/verwijderen)."""
    if not os.path.exists(DATA_FILE):
        return
    try:
        os.makedirs(BACKUP_DIR, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f")
        shutil.copy2(DATA_FILE, os.path.join(BACKUP_DIR, f"profiles-{stamp}.json"))
        backups = sorted(os.listdir(BACKUP_DIR))
        for old in backups[:-MAX_BACKUPS]:
            try:
                os.remove(os.path.join(BACKUP_DIR, old))
            except Exception:
                pass
    except Exception as e:
        print(f"Fout bij back-uppen profiles: {e}")


async def save_profiles_list(data: dict):
    await asyncio.to_thread(_backup_sync)
    await save(data)


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
    async with _lock:
        data = await load()
        return data["profiles"]


@router.post("/")
async def create_profile(profile: ProfileCreate):
    async with _lock:
        data = await load()
        new_id = profile.id or str(int(time.time() * 1000))
        entry = {"id": new_id, "name": profile.name, "pin": profile.pin,
                 "colorIndex": profile.colorIndex, "icon": profile.icon}
        data["profiles"].append(entry)
        await save_profiles_list(data)
        return entry


@router.put("/{profile_id}")
async def update_profile(profile_id: str, profile: ProfileUpdate):
    async with _lock:
        data = await load()
        for p in data["profiles"]:
            if p["id"] == profile_id:
                p.update({"name": profile.name, "pin": profile.pin,
                          "colorIndex": profile.colorIndex, "icon": profile.icon})
                await save_profiles_list(data)
                return p
        raise HTTPException(status_code=404, detail="Profiel niet gevonden")


@router.delete("/{profile_id}")
async def delete_profile(profile_id: str):
    async with _lock:
        data = await load()
        data["profiles"] = [p for p in data["profiles"] if p["id"] != profile_id]
        data["data"].pop(profile_id, None)
        await save_profiles_list(data)
        return {"ok": True}


# --- Watchlist ---

@router.get("/{profile_id}/watchlist")
async def get_watchlist(profile_id: str):
    async with _lock:
        data = await load()
        return _profile_data(data, profile_id)["watchlist"]


@router.post("/{profile_id}/watchlist")
async def add_to_watchlist(profile_id: str, item: WatchlistItem):
    async with _lock:
        data = await load()
        pd = _profile_data(data, profile_id)
        if not any(w["id"] == item.id for w in pd["watchlist"]):
            pd["watchlist"].insert(0, item.dict())
            await save(data)
        return {"ok": True}


@router.delete("/{profile_id}/watchlist/{item_id}")
async def remove_from_watchlist(profile_id: str, item_id: int):
    async with _lock:
        data = await load()
        pd = _profile_data(data, profile_id)
        pd["watchlist"] = [w for w in pd["watchlist"] if w["id"] != item_id]
        await save(data)
        return {"ok": True}


# --- Voortgang ---

@router.get("/{profile_id}/progress")
async def get_all_progress(profile_id: str):
    async with _lock:
        data = await load()
        return list(_profile_data(data, profile_id)["progress"].values())


@router.post("/{profile_id}/progress")
async def save_progress(profile_id: str, item: ProgressItem):
    async with _lock:
        data = await load()
        pd = _profile_data(data, profile_id)
        pd["progress"][str(item.id)] = item.dict()
        await save(data)
        return {"ok": True}


@router.delete("/{profile_id}/progress/{item_id}")
async def delete_progress(profile_id: str, item_id: str):
    async with _lock:
        data = await load()
        pd = _profile_data(data, profile_id)
        pd["progress"].pop(str(item_id), None)
        await save(data)
        return {"ok": True}


# --- Persoonlijke rangschikking (1-3 sterren) ---

@router.get("/{profile_id}/ratings")
async def get_ratings(profile_id: str):
    async with _lock:
        data = await load()
        return _profile_data(data, profile_id)["ratings"]


@router.post("/{profile_id}/ratings")
async def set_rating(profile_id: str, item: RatingItem):
    async with _lock:
        data = await load()
        pd = _profile_data(data, profile_id)
        pd["ratings"][str(item.id)] = item.dict()
        await save(data)
        return {"ok": True}


@router.delete("/{profile_id}/ratings/{item_id}")
async def clear_rating(profile_id: str, item_id: int):
    async with _lock:
        data = await load()
        pd = _profile_data(data, profile_id)
        pd["ratings"].pop(str(item_id), None)
        await save(data)
        return {"ok": True}
