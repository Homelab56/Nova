import os
import json
from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter()
DATA_FILE = "/app/data/userdata.json"


def load() -> dict:
    if os.path.exists(DATA_FILE):
        with open(DATA_FILE) as f:
            return json.load(f)
    return {"watchlist": [], "progress": {}}


def save(data: dict):
    os.makedirs(os.path.dirname(DATA_FILE), exist_ok=True)
    with open(DATA_FILE, "w") as f:
        json.dump(data, f, indent=2)


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


# --- Watchlist ---

@router.get("/watchlist")
def get_watchlist():
    return load()["watchlist"]


@router.post("/watchlist")
def add_to_watchlist(item: WatchlistItem):
    data = load()
    if not any(w["id"] == item.id for w in data["watchlist"]):
        data["watchlist"].insert(0, item.dict())
        save(data)
    return {"ok": True}


@router.delete("/watchlist/{item_id}")
def remove_from_watchlist(item_id: int):
    data = load()
    data["watchlist"] = [w for w in data["watchlist"] if w["id"] != item_id]
    save(data)
    return {"ok": True}


# --- Voortgang ---

@router.get("/progress")
def get_all_progress():
    return list(load()["progress"].values())


@router.post("/progress")
def save_progress(item: ProgressItem):
    data = load()
    data["progress"][str(item.id)] = item.dict()
    save(data)
    return {"ok": True}


@router.delete("/progress/{item_id}")
def delete_progress(item_id: str):
    data = load()
    data["progress"].pop(str(item_id), None)
    save(data)
    return {"ok": True}
