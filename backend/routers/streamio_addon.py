import re
import urllib.parse
import httpx
from fastapi import APIRouter, Request

from .search import tmdb_get
from .debrid import search_and_stream
from .config_loader import get_aiostreams_stremio_addon_url

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


def _parse_extra_params(extra: str) -> dict:
    """"videoHash=X&videoSize=Y&filename=Z" (nog URL-gecodeerd, want dit is het
    padsegment zelf) -> {'videoHash': X, 'videoSize': Y, 'filename': Z}. Nuvio
    stuurt dit mee, berekend uit het bestand dat effectief afgespeeld wordt -
    de sleutel om een referentiestream te vinden die bij dezelfde release
    hoort i.p.v. een willekeurige andere (zie _best_matching_stream_url)."""
    result: dict[str, str] = {}
    for pair in extra.split("&"):
        if "=" not in pair:
            continue
        k, _, v = pair.partition("=")
        result[urllib.parse.unquote(k)] = urllib.parse.unquote(v)
    return result


def _normalize_filename(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", name.lower())


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


async def _aiostreams_candidates(stremio_type: str, id_: str) -> list[dict]:
    """Alle stream-kandidaten van AIOStreams (dezelfde Stremio-stream-endpoint
    die Nuvio zelf ook gebruikt) voor deze titel, met hun url + behaviorHints
    (filename/videoSize) - zodat de caller de release kan kiezen die het best
    overeenkomt met wat er effectief afgespeeld wordt."""
    base = get_aiostreams_stremio_addon_url()
    if not base:
        return []
    url = f"{base}/stream/{stremio_type}/{id_}.json"
    try:
        async with httpx.AsyncClient(timeout=20) as client:
            r = await client.get(url)
            if r.status_code != 200:
                return []
            data = r.json()
    except Exception:
        return []
    return [s for s in (data.get("streams") or []) if s.get("url")]


def _best_matching_stream_url(
    candidates: list[dict], filename_hint: str | None, size_hint: int | None
) -> str | None:
    """Een verkeerde (andere release/montage dan wat je effectief afspeelt)
    referentiestream geeft ffsubsync een perfecte sync op de vérkeerde audio -
    dat toont zich als een vast tijdsverschil, niet als drift. Kiest daarom
    bewust de kandidaat die overeenkomt met het bestand dat Nuvio meestuurt
    i.p.v. gewoon de eerste te nemen."""
    if not candidates:
        return None
    if filename_hint:
        target = _normalize_filename(filename_hint)
        for s in candidates:
            fn = (s.get("behaviorHints") or {}).get("filename")
            if fn and _normalize_filename(fn) == target:
                return s["url"]
    if size_hint:
        def size_diff(s: dict) -> float:
            sz = (s.get("behaviorHints") or {}).get("videoSize")
            return abs(sz - size_hint) if isinstance(sz, (int, float)) else float("inf")
        best = min(candidates, key=size_diff)
        if size_diff(best) != float("inf"):
            return best["url"]
    return candidates[0]["url"]


async def _resolve_subtitles(
    stremio_type: str, id_: str, request: Request, extra_params: dict | None = None
) -> dict:
    imdb_id, season, episode = _parse_stremio_id(id_)
    if not imdb_id.startswith("tt"):
        return {"subtitles": []}
    media_type = "tv" if stremio_type == "series" else "movie"

    tmdb_id, title, year = await _imdb_to_tmdb(imdb_id, media_type)
    if not tmdb_id or not title:
        return {"subtitles": []}

    filename_hint = (extra_params or {}).get("filename")
    size_raw = (extra_params or {}).get("videoSize")
    size_hint = int(size_raw) if size_raw and size_raw.isdigit() else None

    stream_url: str | None = None

    # Weten we welk bestand Nuvio effectief afspeelt? Dan eerst proberen
    # daarmee te matchen tegen AIOStreams' kandidatenlijst - veel
    # betrouwbaarder dan gokken, want een andere release/montage geeft
    # ffsubsync een verkeerde (maar wél intern consistente) referentie.
    if filename_hint or size_hint:
        candidates = await _aiostreams_candidates(stremio_type, id_)
        stream_url = _best_matching_stream_url(candidates, filename_hint, size_hint)

    if not stream_url:
        if media_type == "tv" and season and episode:
            q = f"{title} S{season:02d}E{episode:02d}"
        else:
            q = f"{title} {year or ''}".strip()
        # In-process aanroep i.p.v. een eigen HTTP-request naar /debrid/search -
        # hergebruikt zo dezelfde cache/semaphore als Nova's eigen frontend al doet.
        try:
            result = await search_and_stream(q=q, tmdb_id=tmdb_id, media_type=media_type)
        except Exception:
            result = None
        stream_url = (result or {}).get("direct_url") or (result or {}).get("stream_url")

    if not stream_url:
        # Nova's eigen zoekopdracht vond niets - probeer rechtstreeks bij
        # AIOStreams (dezelfde bron die de gebruiker al succesvol gebruikt om
        # dit gewoon af te spelen) vóór helemaal op te geven.
        candidates = await _aiostreams_candidates(stremio_type, id_)
        stream_url = _best_matching_stream_url(candidates, None, None)

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
    return await _resolve_subtitles(type, id, request, extra_params=_parse_extra_params(extra))
