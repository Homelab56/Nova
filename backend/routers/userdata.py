import os
import json
from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter()
DATA_FILE = "/app/data/userdata.json"


import os
import json
import asyncio
from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter()
DATA_FILE = "/app/data/userdata.json"

def _load_sync() -> dict:
    if os.path.exists(DATA_FILE):
        try:
            with open(DATA_FILE, "r") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    data.setdefault("watchlist", [])
                    data.setdefault("progress", {})
                    data.setdefault("prefs", {})
                    return data
        except Exception as e:
            print(f"Fout bij laden userdata: {e}")
    return {"watchlist": [], "progress": {}, "prefs": {}}

def _save_sync(data: dict):
    try:
        os.makedirs(os.path.dirname(DATA_FILE), exist_ok=True)
        with open(DATA_FILE, "w") as f:
            json.dump(data, f, indent=2)
    except Exception as e:
        print(f"Fout bij opslaan userdata: {e}")

async def load() -> dict:
    return await asyncio.to_thread(_load_sync)

async def save(data: dict):
    await asyncio.to_thread(_save_sync, data)

class WatchlistItem(BaseModel):
    id: int
    title: str
    poster_path: str = ""
    backdrop_path: str = ""
    media_type: str = "movie"
    release_date: str = ""
    first_air_date: str = ""
    vote_average: float = 0.0
    overview: str = ""

class ProgressItem(BaseModel):
    id: int | str
    title: str
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

class UserPrefs(BaseModel):
    default_audio_lang: str = "en"
    default_sub_lang_1: str = "nl"
    default_sub_lang_2: str = "nl-be"
    subtitles_enabled: bool = True

# --- Watchlist ---

@router.get("/watchlist")
async def get_watchlist():
    data = await load()
    return data["watchlist"]

@router.post("/watchlist")
async def add_to_watchlist(item: WatchlistItem):
    data = await load()
    if not any(w["id"] == item.id for w in data["watchlist"]):
        data["watchlist"].insert(0, item.dict())
        await save(data)
    return {"ok": True}

@router.delete("/watchlist/{item_id}")
async def remove_from_watchlist(item_id: int):
    data = await load()
    data["watchlist"] = [w for w in data["watchlist"] if w["id"] != item_id]
    await save(data)
    return {"ok": True}

# --- Voortgang ---

@router.get("/progress")
async def get_all_progress():
    data = await load()
    return list(data["progress"].values())

@router.post("/progress")
async def save_progress(item: ProgressItem):
    data = await load()
    data["progress"][str(item.id)] = item.dict()
    await save(data)
    return {"ok": True}

@router.delete("/progress/{item_id}")
async def delete_progress(item_id: str):
    data = await load()
    data["progress"].pop(str(item_id), None)
    await save(data)
    return {"ok": True}

@router.get("/prefs")
async def get_prefs():
    data = await load()
    return data.get("prefs") or {}

@router.post("/prefs")
async def save_prefs(prefs: UserPrefs):
    data = await load()
    data["prefs"] = prefs.dict()
    await save(data)
    return {"ok": True}
