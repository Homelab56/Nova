import urllib.parse
from fastapi import APIRouter, Request

from .search import tmdb_get
from .debrid import search_and_stream

router = APIRouter()

# Stremio-addon dat Nuvio/Streamio kan toevoegen via "Add Addon by URL" - geeft
# geen eigen ondertitel-logica, maar wijst gewoon terug naar de al bestaande,
# geteste OpenSubtitles+ffsubsync-pijplijn in stream.py
# (/stream/subtitle-external.vtt). Nuvio verwacht Stremio's protocol (IMDB-
# id's, "movie"/"series"), Nova's backend draait op TMDB-id's en "movie"/"tv" -
# deze router is enkel het vertaallaagje ertussen.
ADDON_ID = "com.streamio.subtitles"
ADDON_VERSION = "1.0.0"


@router.get("/manifest.json")
async def manifest():
    return {
        "id": ADDON_ID,
        "name": "Streamio Subtitles",
        "version": ADDON_VERSION,
        "description": "Nederlandse ondertitels via OpenSubtitles, automatisch gesynchroniseerd op de audio met ffsubsync.",
        "resources": ["subtitles"],
        "types": ["movie", "series"],
        "idPrefixes": ["tt"],
    }


def _parse_stremio_id(id_: str) -> tuple[str, int | None, int | None]:
    """"tt1234567" (film) of "tt1234567:1:2" (S1E2) -> (imdb_id, season, episode)."""
    parts = id_.split(":")
    imdb_id = parts[0]
    season = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
    episode = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else None
    return imdb_id, season, episode


async def _imdb_to_tmdb(imdb_id: str, media_type: str) -> tuple[int | None, str | None, int | None]:
    """(tmdb_id, titel, jaar), of (None, None, None) als niet gevonden. Stremio/
    Nuvio identificeert content via IMDB-id's; Nova's hele backend (OpenSubtitles-
    zoekopdracht, cache-key, ...) draait op TMDB-id's - vandaar deze opzoeking."""
    try:
        data = await tmdb_get(f"/find/{imdb_id}", {"external_source": "imdb_id"})
    except Exception:
        return None, None, None
    key = "tv_results" if media_type == "tv" else "movie_results"
    results = data.get(key) or []
    if not results:
        # Soms staat een titel enkel bij het andere type geregistreerd op TMDB.
        other_key = "movie_results" if key == "tv_results" else "tv_results"
        results = data.get(other_key) or []
    if not results:
        return None, None, None
    item = results[0]
    title = item.get("title") or item.get("name")
    date = item.get("release_date") or item.get("first_air_date") or ""
    year = int(date[:4]) if len(date) >= 4 and date[:4].isdigit() else None
    return item.get("id"), title, year


async def _resolve_subtitles(stremio_type: str, id_: str, request: Request) -> dict:
    imdb_id, season, episode = _parse_stremio_id(id_)
    if not imdb_id.startswith("tt"):
        return {"subtitles": []}
    media_type = "tv" if stremio_type == "series" else "movie"

    tmdb_id, title, year = await _imdb_to_tmdb(imdb_id, media_type)
    if not tmdb_id or not title:
        return {"subtitles": []}

    if media_type == "tv" and season and episode:
        q = f"{title} S{season:02d}E{episode:02d}"
    else:
        q = f"{title} {year or ''}".strip()

    # In-process aanroep i.p.v. een eigen HTTP-request naar /debrid/search -
    # hergebruikt zo dezelfde cache/semaphore als Nova's eigen frontend al doet.
    # We lossen bewust zelf een referentiestream op i.p.v. te vertrouwen op wat
    # Nuvio's speler koos: ffsubsync heeft enkel een correct passende audiotrack
    # nodig, geen byte-identieke bron.
    try:
        result = await search_and_stream(q=q, tmdb_id=tmdb_id, media_type=media_type)
    except Exception:
        return {"subtitles": []}
    stream_url = (result or {}).get("direct_url") or (result or {}).get("stream_url")
    if not stream_url:
        return {"subtitles": []}

    params = {
        "url": stream_url,
        "tmdb_id": str(tmdb_id),
        "media_type": media_type,
        "lang": "nl",
    }
    if season and episode:
        params["season"] = str(season)
        params["episode"] = str(episode)
    subtitle_url = f"{str(request.base_url).rstrip('/')}/stream/subtitle-external.vtt?{urllib.parse.urlencode(params)}"

    return {"subtitles": [{"id": f"streamio-nl-{tmdb_id}", "url": subtitle_url, "lang": "nl"}]}


@router.get("/subtitles/{type}/{id}.json")
async def get_subtitles(type: str, id: str, request: Request):
    return await _resolve_subtitles(type, id, request)


@router.get("/subtitles/{type}/{id}/{extra}.json")
async def get_subtitles_with_extra(type: str, id: str, extra: str, request: Request):
    # De extra padsegment (videoHash=...&videoSize=...&filename=...) hebben we
    # niet nodig - we lossen hierboven zelf een referentiestream op - maar de
    # route moet wel bestaan zodat Nuvio's variant met die parameters niet
    # gewoon 404 geeft.
    return await _resolve_subtitles(type, id, request)
