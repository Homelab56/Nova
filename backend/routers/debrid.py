import httpx
import os
import re
import asyncio
import urllib.parse
import base64
import time
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from .config_loader import get_rd_token, get_tmdb_key, get_aiostreams_config
from .stream import _ffprobe_subtitle_streams

router = APIRouter()

RD_BASE = "https://api.real-debrid.com/rest/1.0"
TMDB_BASE = "https://api.themoviedb.org/3"

# Cache om te voorkomen dat dezelfde zoekopdracht te vaak wordt uitgevoerd
_search_cache = {}
_cache_ttl = 30  # 30 seconden cache


def rd_headers():
    return {"Authorization": f"Bearer {get_rd_token()}"}


def _aiostreams_request_headers(cfg: dict) -> dict:
    h: dict[str, str] = {}
    b64_ud = (cfg.get("user_data_b64") or "").strip()
    if b64_ud:
        h["x-aiostreams-user-data"] = b64_ud
        return h
    user = (cfg.get("username") or "").strip()
    password = (cfg.get("password") or "").strip()
    if user and password:
        token = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
        h["Authorization"] = f"Basic {token}"
    return h


def _aiostreams_search_id(media_type: str | None, tmdb_id: int, q: str) -> tuple[str | None, str | None]:
    """Geeft (aio_type, id_param) voor GET /api/v1/search of (None, None) als niet te bouwen."""
    if not tmdb_id or media_type not in {"movie", "tv"}:
        return None, None
    if media_type == "movie":
        return "movie", f"tmdb:{int(tmdb_id)}"
    ep = _episode_token(q or "")
    if not ep:
        return None, None
    m = re.fullmatch(r"s(\d{2})e(\d{2})", ep)
    if not m:
        return None, None
    season = int(m.group(1))
    episode = int(m.group(2))
    return "series", f"tmdb:{int(tmdb_id)}:{season}:{episode}"


def _aio_rank_result(item: dict) -> tuple[int, int]:
    name = (
        str(item.get("name") or "")
        + " "
        + str(item.get("filename") or "")
        + " "
        + str((item.get("parsedFile") or {}).get("resolution") or "")
    ).lower()
    size = 0
    try:
        size = int(item.get("size") or 0)
    except Exception:
        size = 0
    # "AI upscale"-releases zijn zelden echt hogere kwaliteit, wel enorm groot
    # (waardoor ze anders de tie-break op bestandsgrootte winnen) en vaak te
    # zwaar om vlot af te spelen. Nooit automatisch als beste kiezen.
    if any(x in name for x in ("ai upscale", "ai-upscale", "upscaled", "ai upscaled")):
        return (-1, size)
    tier = 0
    if any(x in name for x in ("2160", "4k", "uhd", "4320")):
        tier = 4000
    elif "1440" in name or "1080" in name:
        tier = 3000
    elif "720" in name:
        tier = 2000
    elif "480" in name:
        tier = 1000
    if item.get("cached"):
        tier += 50
    return (tier, size)


_JUNK_RELEASE_MARKERS = ("ai upscale", "ai-upscale", "upscaled", "ai upscaled")


def _looks_like_junk_release(item: dict) -> bool:
    """
    Releases die zichzelf als "AI upscale" aanprijzen zijn zelden echt hogere
    kwaliteit en vaak te zwaar om vlot af te spelen. Deze worden overal
    volledig uitgesloten (niet enkel laag gerankt), zodat ze ook nooit via
    een ondertitel-fallback alsnog gekozen kunnen worden wanneer er weinig
    andere resultaten zijn.
    """
    name = (str(item.get("name") or "") + " " + str(item.get("filename") or "")).lower()
    return any(x in name for x in _JUNK_RELEASE_MARKERS)


async def _fetch_aiostreams_results(
    cfg: dict,
    aio_type: str,
    aio_id: str,
    timeout: float = 55.0,
) -> list[dict]:
    base = (cfg.get("base_url") or "").rstrip("/")
    if not base:
        return []
    params = {"type": aio_type, "id": aio_id, "format": "true"}
    headers = _aiostreams_request_headers(cfg)
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.get(f"{base}/api/v1/search", params=params, headers=headers)
    except Exception as e:
        print(f"AIOStreams search fout: {e}")
        return []
    try:
        payload = r.json()
    except Exception:
        return []
    if not payload.get("success"):
        print(f"AIOStreams API: {payload.get('error') or r.status_code}")
        return []
    data = payload.get("data") or {}
    results = data.get("results") or []
    results = [x for x in results if isinstance(x, dict)]
    # AIOStreams geeft soms zijn interne poort (8086) mee i.p.v. de poort
    # waarop de service echt bereikbaar is (3003). Dit hier al normaliseren
    # zodat ranking, ffprobe-checks én de uiteindelijke afspeel-URL allemaal
    # dezelfde (werkende) URL gebruiken - anders faalt ffprobe stilletjes met
    # "connection refused" en lijkt de bron onterecht kapot/zonder subs.
    for item in results:
        url = item.get("url")
        if isinstance(url, str) and ":8086" in url:
            item["url"] = url.replace(":8086", ":3003")
    return results


def _wrap_stream_value(url: str, not_ready: bool) -> str:
    if not_ready or url.startswith("magnet:"):
        return f"/api/stream/play?url={urllib.parse.quote(url, safe='')}"
    return url


def _pick_best_aiostream_url(results: list[dict]) -> tuple[str | None, dict | None]:
    with_url = [x for x in results if (x.get("url") or "").strip() and not _looks_like_junk_release(x)]
    if not with_url:
        return None, None
    with_url.sort(key=_aio_rank_result, reverse=True)
    best = with_url[0]
    url = (best.get("url") or "").strip()
    if not url:
        return None, None
    return _wrap_stream_value(url, bool(best.get("notWebReady"))), best


_NL_LANG_PREFIXES = ("nl", "nld", "dut", "vla", "dutch", "vlaams", "flemish")


def _subtitle_is_dutch(s: dict) -> bool:
    tags = s.get("tags") or {}
    if not isinstance(tags, dict):
        tags = {}
    lang = str(tags.get("language") or "").lower()
    title = str(tags.get("title") or "").lower()
    return any(lang.startswith(p) for p in _NL_LANG_PREFIXES) or any(p in title for p in _NL_LANG_PREFIXES)


_EN_LANG_PREFIXES = ("en", "eng", "english")


def _subtitle_is_english(s: dict) -> bool:
    tags = s.get("tags") or {}
    if not isinstance(tags, dict):
        tags = {}
    lang = str(tags.get("language") or "").lower()
    title = str(tags.get("title") or "").lower()
    return any(lang.startswith(p) for p in _EN_LANG_PREFIXES) or any(p in title for p in _EN_LANG_PREFIXES)


async def _probe_subtitle_langs(url: str, timeout: float = 12.0) -> tuple[bool, bool, bool]:
    """
    Opent de bron echt (ffprobe) en geeft (probe_ok, has_nl, has_en) terug.
    probe_ok=False betekent dat de bron niet eens geopend kon worden (kapotte
    of onbereikbare link) - dat is een sterk signaal dat afspelen sowieso
    zal mislukken.
    """
    if not url or url.startswith("magnet:"):
        return False, False, False
    try:
        streams = await asyncio.wait_for(_ffprobe_subtitle_streams(url, is_path=False), timeout=timeout)
    except Exception:
        return False, False, False
    has_nl = any(_subtitle_is_dutch(s) for s in streams)
    has_en = any(_subtitle_is_english(s) for s in streams)
    return True, has_nl, has_en


async def _pick_best_with_dutch_subs(results: list[dict], max_probe: int = 10) -> tuple[str | None, dict | None, bool]:
    """
    Zoals _pick_best_aiostream_url, maar probeert eerst onder de best-gerankte
    kandidaten er één te vinden met bevestigde Nederlandse ondertitels (via
    ffprobe op het echte bestand, niet enkel de bestandsnaam). Is er geen
    enkele met NL, dan telt een bevestigde Engelse ondertitel als tweede keus.
    Geeft (stream_value, item, has_nl_subs) terug.
    """
    with_url = [x for x in results if (x.get("url") or "").strip() and not _looks_like_junk_release(x)]
    if not with_url:
        return None, None, False
    with_url.sort(key=_aio_rank_result, reverse=True)

    candidates = with_url[:max_probe]
    checks = await asyncio.gather(
        *[_probe_subtitle_langs((c.get("url") or "").strip()) for c in candidates],
        return_exceptions=True,
    )
    probed = [(item, r) for item, r in zip(candidates, checks) if not isinstance(r, Exception)]

    for item, (_ok, has_nl, _has_en) in probed:
        if has_nl:
            url = (item.get("url") or "").strip()
            return _wrap_stream_value(url, bool(item.get("notWebReady"))), item, True

    for item, (_ok, _has_nl, has_en) in probed:
        if has_en:
            url = (item.get("url") or "").strip()
            return _wrap_stream_value(url, bool(item.get("notWebReady"))), item, False

    # Geen van de geprobeerde kandidaten heeft bevestigd NL- of EN-ondertitels;
    # val terug op de gewone beste match zodat afspelen niet vastloopt.
    fallback_url, fallback_item = _pick_best_aiostream_url(results)
    return fallback_url, fallback_item, False


_VIDEO_EXTS = (".mkv", ".mp4", ".m4v", ".avi", ".mov", ".webm", ".ts")

def _normalize_text(s: str) -> str:
    if not s:
        return ""
    s = s.lower()
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()

_STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "by", "de", "den", "der", "des",
    "een", "en", "for", "het", "i", "in", "is", "la", "le", "les", "of", "on",
    "or", "the", "to", "van", "von", "with",
}

def _is_year_token(w: str) -> bool:
    return bool(re.fullmatch(r"(19\d{2}|20\d{2})", w or ""))

def _words(s: str) -> list[str]:
    s = _normalize_text(s)
    raw = [w for w in s.split() if len(w) >= 2]
    if not raw:
        return []
    filtered = [w for w in raw if w not in _STOPWORDS]
    words = filtered if filtered else raw
    return [w for w in words if not _is_year_token(w)]

def _strip_trailing_year(q: str) -> str:
    return re.sub(r"\s\d{4}$", "", q).strip()

def _extract_years(s: str) -> set[int]:
    if not s:
        return set()
    years = set()
    for m in re.finditer(r"\b(19\d{2}|20\d{2})\b", s):
        try:
            y = int(m.group(1))
            years.add(y)
        except Exception:
            pass
    return years

def _candidate_year(q: str) -> int | None:
    years = _extract_years(q)
    if not years:
        return None
    m = re.search(r"(19\d{2}|20\d{2})\s*$", q.strip())
    if m:
        try:
            return int(m.group(1))
        except Exception:
            return None
    return max(years)

def _min_score(words: list[str], is_library: bool = False) -> int:
    n = len(words)
    if n <= 0:
        return 0
    if n == 1:
        return 1
    # Library matching mag iets losser zijn (2-4), external strict (tot 5)
    return min(4 if is_library else 5, n)

def _required_score(words: list[str], media_type: str | None, base_year: int | None, is_library: bool) -> int:
    if media_type == "movie" and base_year:
        return len(words)
    return _min_score(words, is_library=is_library)

def _infer_base_year(q: str, candidates: list[str], media_type: str | None) -> int | None:
    y = _candidate_year(q)
    if y:
        return y
    if media_type != "movie":
        return None
    years = [(_candidate_year(c) or 0) for c in candidates]
    years = [yy for yy in years if yy > 0]
    return max(years) if years else None

def _filter_candidates_for_year(word_sets: list[tuple[list[str], str]], base_year: int | None) -> list[tuple[list[str], str]]:
    if not base_year:
        return word_sets
    out = []
    for words, candidate_q in word_sets:
        cy = _candidate_year(candidate_q)
        if cy == base_year:
            out.append((words, candidate_q))
    return out or word_sets

def _is_video_path(path: str) -> bool:
    p = (path or "").lower()
    return any(p.endswith(ext) for ext in _VIDEO_EXTS)

def _episode_token(raw: str) -> str | None:
    s = (raw or "").lower()
    m = re.search(r"\bs(\d{1,2})e(\d{1,2})\b", s)
    if m:
        ss, ee = m.groups()
        return f"s{int(ss):02d}e{int(ee):02d}"
    m = re.search(r"\b(\d{1,2})x(\d{1,2})\b", s)
    if m:
        ss, ee = m.groups()
        return f"s{int(ss):02d}e{int(ee):02d}"
    return None

def _select_best_link_index(info: dict, q: str, media_type: str | None, base_year: int | None) -> int | None:
    files = info.get("files") or []
    links = info.get("links") or []
    if not files or not links:
        return None

    selected = []
    for f in files:
        try:
            if int(f.get("selected") or 0) == 1:
                selected.append(f)
        except Exception:
            pass
    if not selected:
        selected = files[: len(links)]

    episode_token = _episode_token(q or "")

    words = _words(q or "")
    words_for_score = [w for w in words if not re.fullmatch(r"s\d{2}e\d{2}", w or "")]
    min_words = len(words)
    if media_type == "movie":
        min_words = 1 if len(words) <= 1 else 2
    elif media_type == "tv":
        min_words = 1 if len(words) <= 1 else 2
    min_words = min(min_words, len(words_for_score)) if words_for_score else min_words

    ep_variants = None
    if episode_token:
        mm = re.fullmatch(r"s(\d{2})e(\d{2})", episode_token)
        if mm:
            ss, ee = mm.groups()
            ssi = int(ss)
            eei = int(ee)
            ep_variants = {
                episode_token,
                f"{ssi}x{eei:02d}",
                f"{ssi:02d}x{eei:02d}",
            }

    best_idx = None
    best_score = -10_000
    best_size = -1

    link_count = min(len(selected), len(links))
    for link_idx in range(link_count):
        f = selected[link_idx] or {}
        path = f.get("path") or ""
        if not _is_video_path(path):
            continue

        norm = _normalize_text(path)
        if "sample" in norm or "trailer" in norm:
            continue

        size = 0
        try:
            size = int(f.get("bytes") or 0)
        except Exception:
            size = 0
        if size and size < 200 * 1024 * 1024:
            continue

        years = _extract_years(path)
        if media_type == "movie" and base_year and years and base_year not in years:
            continue

        score = sum(1 for w in words_for_score if w in norm)
        if ep_variants:
            if not any(t in norm for t in ep_variants):
                continue
            score += 10

        if score < min_words:
            continue

        if score > best_score or (score == best_score and size > best_size):
            best_score = score
            best_size = size
            best_idx = link_idx

    return best_idx

async def _tmdb_alt_titles(tmdb_id: int, media_type: str) -> list[str]:
    if not tmdb_id or media_type not in {"movie", "tv"}:
        return []
    path = f"/{media_type}/{tmdb_id}/alternative_titles"
    params = {"api_key": get_tmdb_key()}
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"{TMDB_BASE}{path}", params=params, timeout=10)
            if r.status_code != 200:
                return []
            data = r.json()
    except Exception:
        return []

    out = []
    for item in (data.get("titles") or data.get("results") or []):
        t = item.get("title")
        if isinstance(t, str) and t.strip():
            out.append(t.strip())
    return out

async def _tmdb_year(tmdb_id: int, media_type: str) -> int | None:
    if not tmdb_id or media_type not in {"movie", "tv"}:
        return None
    path = f"/{media_type}/{tmdb_id}"
    params = {"api_key": get_tmdb_key()}
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"{TMDB_BASE}{path}", params=params, timeout=10)
            if r.status_code != 200:
                return None
            data = r.json()
    except Exception:
        return None

    date_str = data.get("release_date") if media_type == "movie" else data.get("first_air_date")
    if not isinstance(date_str, str) or len(date_str) < 4:
        return None
    try:
        return int(date_str[:4])
    except Exception:
        return None

async def _tmdb_main_titles(tmdb_id: int, media_type: str) -> list[str]:
    if not tmdb_id or media_type not in {"movie", "tv"}:
        return []
    path = f"/{media_type}/{tmdb_id}"
    params = {"api_key": get_tmdb_key()}
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"{TMDB_BASE}{path}", params=params, timeout=10)
            if r.status_code != 200:
                return []
            data = r.json()
    except Exception:
        return []

    out = []
    keys = ["title", "original_title"] if media_type == "movie" else ["name", "original_name"]
    for k in keys:
        v = data.get(k)
        if isinstance(v, str) and v.strip():
            out.append(v.strip())
    seen = set()
    uniq = []
    for t in out:
        n = _normalize_text(t)
        if not n or n in seen:
            continue
        seen.add(n)
        uniq.append(t)
    return uniq

async def _candidate_queries(q: str, tmdb_id: int | None, media_type: str | None) -> list[str]:
    """Genereert zoektermen voor scrapers."""
    base = q.strip()
    if not base: return []
    candidates = [base]
    
    if media_type == "tv":
        ep = _episode_token(base)
        if ep:
            show_part = re.sub(r"\bs\d{1,2}e\d{1,2}\b", "", base, flags=re.IGNORECASE).strip()
            show_part = re.sub(r"\b\d{1,2}x\d{1,2}\b", "", show_part, flags=re.IGNORECASE).strip()
            show_part = re.sub(r"\s+", " ", show_part).strip()
            if show_part and show_part.lower() != base.lower():
                candidates.append(f"{show_part} {ep.upper()}")

    seen = set()
    out = []
    for c in candidates:
        k = _normalize_text(c)
        if not k or k in seen: continue
        seen.add(k)
        out.append(c)
    return out

async def _old_candidate_queries_deleted():
    pass

class MagnetRequest(BaseModel):
    magnet: str


@router.get("/library")
async def get_library():
    """
    Haalt de Real-Debrid torrent lijst op en probeert deze te mappen naar TMDB items.
    Dit is voor de 'Mijn Bibliotheek' rij op het hoofdscherm.
    """
    async with httpx.AsyncClient() as client:
        r = await client.get(
            f"{RD_BASE}/torrents",
            headers=rd_headers(),
            params={"limit": 100}
        )
        if r.status_code != 200:
            return []

        torrents = r.json()
    
    print(f"Haal bibliotheek op: {len(torrents)} torrents")
    # Filter op gedownloade torrents en return hun filenames voor nu
    # De frontend kan deze mappen naar TMDB items indien gewenst
    return [
        {
            "id": t["id"],
            "filename": t["filename"],
            "status": t["status"],
            "added": t["added"],
            "links": t.get("links", [])
        }
        for t in torrents if t["status"] == "downloaded"
    ]


@router.get("/check")
async def check_availability(q: str, tmdb_id: int | None = None, media_type: str | None = None):
    """
    Checkt of er waarschijnlijk een stream is (AIOStreams en/of Real-Debrid bibliotheek).
    """
    candidates = await _candidate_queries(q, tmdb_id, media_type)
    is_movie = (media_type == "movie")
    base_year = _infer_base_year(q, candidates, media_type)
    if is_movie and not base_year:
        return {"available": False}
    if is_movie and base_year:
        candidates = [c for c in candidates if _candidate_year(c) == base_year]
    word_sets = [(_words(c), c) for c in candidates]
    word_sets = [(w, c) for (w, c) in word_sets if w]
    if not word_sets:
        return {"available": False}
    word_sets = _filter_candidates_for_year(word_sets, base_year)
    ep_token = _episode_token(q or "") if media_type == "tv" else None
    ep_variants = None
    if ep_token:
        m = re.fullmatch(r"s(\d{2})e(\d{2})", ep_token)
        if m:
            ss, ee = m.groups()
            ssi = int(ss)
            eei = int(ee)
            ep_variants = {ep_token, f"{ssi}x{eei:02d}", f"{ssi:02d}x{eei:02d}"}

    aio_cfg = get_aiostreams_config()
    if aio_cfg.get("base_url") and tmdb_id:
        aio_type, aio_id = _aiostreams_search_id(media_type, int(tmdb_id), q)
        if aio_type and aio_id:
            aio_res = await _fetch_aiostreams_results(aio_cfg, aio_type, aio_id, timeout=25.0)
            stream_u, _picked = _pick_best_aiostream_url(aio_res)
            if stream_u:
                return {"available": True}

    async with httpx.AsyncClient(timeout=15) as client:
        try:
            r = await client.get(f"{RD_BASE}/torrents", headers=rd_headers(), params={"limit": 250})
            if r.status_code != 200:
                return {"available": False}
            torrents = r.json()
            primary_word_sets = _filter_candidates_for_year(word_sets, base_year)
            for torrent in torrents:
                if torrent.get("status") != "downloaded":
                    continue
                filename_raw = torrent.get("filename", "") or ""
                filename = _normalize_text(filename_raw)
                if ep_variants and not any(t in filename for t in ep_variants):
                    continue
                for words, _ in primary_word_sets:
                    score = sum(1 for word in words if word in filename)
                    min_score = _required_score(words, media_type, base_year, is_library=True)
                    if score >= min_score:
                        return {"available": True}
        except Exception as e:
            print(f"check RD bibliotheek: {e}")
    return {"available": False}


# Een globale lock om te voorkomen dat de server bezwijkt onder te veel zoekopdrachten
SEARCH_SEMAPHORE = asyncio.Semaphore(2)

@router.get("/search")
async def search_and_stream(q: str, tmdb_id: int | None = None, media_type: str | None = None, client_id: str | None = None):
    """
    Zoekt automatisch naar een beschikbare stream voor een titel.
    Met semaphore om de server te beschermen tegen overbelasting.
    Met cache om te voorkomen dat dezelfde zoekopdracht te vaak wordt uitgevoerd.
    """
    # Cache key
    cache_key = f"{q}:{tmdb_id}:{media_type}"
    current_time = time.time()
    
    # Check cache
    if cache_key in _search_cache:
        cached_result, cached_time = _search_cache[cache_key]
        if current_time - cached_time < _cache_ttl:
            print(f"Cache hit voor: {q}")
            return cached_result
    
    async with SEARCH_SEMAPHORE:
        print(f"--- Start zoekopdracht voor: {q} ({media_type}) ---")
        async with httpx.AsyncClient(timeout=15) as client:
            # Stap 1: Titels bepalen (nu lichtgewicht)
            candidates = await _candidate_queries(q, tmdb_id, media_type)
            is_movie = (media_type == "movie")
            base_year = _infer_base_year(q, candidates, media_type)
            
            if is_movie and not base_year:
                print(f"Geen jaar gevonden voor film: {q}")
                result = {"stream_url": None, "message": f"Geen jaar gevonden voor '{q}'."}
                _search_cache[cache_key] = (result, current_time)
                return result
                
            word_sets = [(_words(c), c) for c in candidates]
            word_sets = [(w, c) for (w, c) in word_sets if w]
            if not word_sets:
                result = {"stream_url": None, "message": "Ongeldige zoekopdracht."}
                _search_cache[cache_key] = (result, current_time)
                return result
                
            ep_token = _episode_token(q or "") if media_type == "tv" else None
            ep_variants = None
            if ep_token:
                m = re.fullmatch(r"s(\d{2})e(\d{2})", ep_token)
                if m:
                    ss, ee = m.groups()
                    ep_variants = {ep_token, f"{int(ss)}x{int(ee):02d}", f"{int(ss):02d}x{int(ee):02d}"}

            aio_cfg = get_aiostreams_config()
            if aio_cfg.get("base_url") and tmdb_id:
                aio_type, aio_id = _aiostreams_search_id(media_type, int(tmdb_id), q)
                if aio_type and aio_id:
                    print(f"AIOStreams: {aio_type} {aio_id}")
                    aio_res = await _fetch_aiostreams_results(aio_cfg, aio_type, aio_id, timeout=55.0)
                    print(f"AIOStreams resultaten: {len(aio_res)} items")
                    stream_url, picked, has_nl_subs = await _pick_best_with_dutch_subs(aio_res)
                    if stream_url:
                        label = (picked or {}).get("name") or (picked or {}).get("filename") or q
                        print(f"AIOStreams stream URL ({'NL subs' if has_nl_subs else 'geen bevestigde NL subs'}): {stream_url[:200]}...")
                        # Vervang poort 8086 met 3003 (AIOStreams draait op 3003)
                        stream_url = stream_url.replace(":8086", ":3003")
                        # Proxy door backend (browser heeft geen toegang tot AIOStreams)
                        result = {
                            "stream_url": f"/api/stream/play?url={urllib.parse.quote(stream_url)}",
                            "direct_url": stream_url,
                            "source": "aiostreams",
                            "title": str(label)[:500],
                            "has_nl_subs": has_nl_subs,
                        }
                        _search_cache[cache_key] = (result, current_time)
                        return result
                    else:
                        print("AIOStreams: geen geldige stream URL gevonden")

            # --- STAP 1: Zoek in eigen RD bibliotheek ---
            print("Checken van Real-Debrid bibliotheek...")
            try:
                r = await client.get(f"{RD_BASE}/torrents", headers=rd_headers(), params={"limit": 250})
                if r.status_code == 200:
                    torrents = r.json()
                    best_match = None
                    best_score = 0
                    
                    primary_word_sets = _filter_candidates_for_year(word_sets, base_year)
                    for torrent in torrents:
                        if torrent.get("status") != "downloaded": continue
                        filename_raw = torrent.get("filename", "") or ""
                        if _looks_like_junk_release({"filename": filename_raw}): continue
                        filename = _normalize_text(filename_raw)
                        if ep_variants and not any(t in filename for t in ep_variants): continue
                        
                        for words, _ in primary_word_sets:
                            score = sum(1 for word in words if word in filename)
                            min_score = _required_score(words, media_type, base_year, is_library=True)
                            if score >= min_score and (score > best_score):
                                best_score = score
                                best_match = torrent

                    if best_match:
                        print(f"Match gevonden in bibliotheek: {best_match['filename']}")
                        info_r = await client.get(f"{RD_BASE}/torrents/info/{best_match['id']}", headers=rd_headers())
                        if info_r.status_code == 200:
                            info = info_r.json()
                            links = info.get("links", [])
                            link_idx = _select_best_link_index(info, q, media_type, base_year)
                            if links and link_idx is not None:
                                ur = await client.post(f"{RD_BASE}/unrestrict/link", headers=rd_headers(), data={"link": links[link_idx]})
                                if ur.status_code == 200:
                                    print("Bibliotheek match succesvol unresticted.")
                                    result = {
                                        "stream_url": ur.json()["download"], # Directe link voor Windows App
                                        "direct_url": ur.json()["download"],
                                        "source": "library",
                                    }
                                    _search_cache[cache_key] = (result, current_time)
                                    return result
            except Exception as e:
                print(f"Fout bij bibliotheek check: {e}")

            # --- STAP 2: Zoek extern ---
            print("Extern zoeken (Jackett/Scrapers)...")
            from .config_loader import get_jackett_config
            jackett = get_jackett_config()
            
            external_torrents = []
            if jackett.get("url") and jackett.get("api_key"):
                try:
                    jr = await client.get(
                        f"{jackett['url'].rstrip('/')}/api/v2.0/indexers/all/results",
                        params={"apikey": jackett["api_key"], "Query": candidates[0], "Category[]": [2000, 5000]},
                        timeout=8
                    )
                    if jr.status_code == 200:
                        for res in jr.json().get("Results", []):
                            if res.get("InfoHash"):
                                external_torrents.append({"title": res.get("Title"), "hash": res.get("InfoHash"), "magnet": res.get("MagnetUri"), "seeders": res.get("Seeders", 0)})
                except Exception as e: 
                    print(f"Jackett timeout of fout: {e}")

            if not external_torrents:
                try:
                    sr = await client.get("https://solidtorrents.to/api/v1/search", params={"q": candidates[0], "category": "video", "sort": "seeders"}, timeout=6)
                    if sr.status_code == 200:
                        for res in sr.json().get("results", []):
                            external_torrents.append({"title": res.get("title"), "hash": res.get("infoHash"), "magnet": res.get("magnet"), "seeders": res.get("swarm", {}).get("seeders", 0)})
                except Exception as e:
                    print(f"SolidTorrents timeout of fout: {e}")

            if not external_torrents:
                print("Geen externe torrents gevonden.")
                result = {"stream_url": None, "message": "Geen streams gevonden."}
                _search_cache[cache_key] = (result, current_time)
                return result

            # --- STAP 3: RD Cache Check ---
            print(f"Cache check op {min(len(external_torrents), 15)} torrents...")
            external_torrents.sort(key=lambda x: x.get("seeders", 0), reverse=True)
            hashes = [t["hash"] for t in external_torrents[:15]]
            try:
                cr = await client.get(f"{RD_BASE}/torrents/instantAvailability/{'/'.join(hashes)}", headers=rd_headers(), timeout=8)
                if cr.status_code == 200:
                    cache_data = cr.json()
                    for t in external_torrents:
                        h = t["hash"].lower()
                        if h in cache_data and cache_data[h].get("rd"):
                            print(f"Cache match gevonden: {t['title']}")
                            ar = await client.post(f"{RD_BASE}/torrents/addMagnet", headers=rd_headers(), data={"magnet": t["magnet"]})
                            if ar.status_code in [200, 201]:
                                tid = ar.json()["id"]
                                await client.post(f"{RD_BASE}/torrents/selectFiles/{tid}", headers=rd_headers(), data={"files": "all"})
                                await asyncio.sleep(0.5)
                                ir = await client.get(f"{RD_BASE}/torrents/info/{tid}", headers=rd_headers())
                                if ir.status_code == 200:
                                    links = ir.json().get("links", [])
                                    if links:
                                        ur = await client.post(f"{RD_BASE}/unrestrict/link", headers=rd_headers(), data={"link": links[0]})
                                        if ur.status_code == 200:
                                            result = {"stream_url": ur.json()["download"], "direct_url": ur.json()["download"], "source": "scraper"}
                                            _search_cache[cache_key] = (result, current_time)
                                            return result
            except Exception as e:
                print(f"Cache check fout: {e}")

            print("Geen afspeelbare streams gevonden na alle stappen.")
            result = {"stream_url": None, "message": "Geen direct afspeelbare streams gevonden."}
            _search_cache[cache_key] = (result, current_time)
            return result


@router.get("/sources")
async def list_sources(q: str, tmdb_id: int | None = None, media_type: str | None = None):
    """
    Geeft alle gevonden AIOStreams-resultaten terug (beste eerst), zonder er
    automatisch één te kiezen. Zo kan de gebruiker zelf een andere bron
    proberen als de automatisch gekozen stream niet goed afspeelt.
    """
    aio_cfg = get_aiostreams_config()
    if not (aio_cfg.get("base_url") and tmdb_id):
        return {"sources": []}
    aio_type, aio_id = _aiostreams_search_id(media_type, int(tmdb_id), q)
    if not aio_type or not aio_id:
        return {"sources": []}

    aio_res = await _fetch_aiostreams_results(aio_cfg, aio_type, aio_id, timeout=55.0)
    with_url = [x for x in aio_res if (x.get("url") or "").strip() and not _looks_like_junk_release(x)]
    with_url.sort(key=_aio_rank_result, reverse=True)

    # Check de best-gerankte kandidaten écht (via ffprobe) op Nederlandse en
    # Engelse ondertitels, i.p.v. enkel op de bestandsnaam af te gaan. Dit
    # ontmaskert ook kapotte/onbereikbare links: die geven net als een bron
    # zonder passende ondertitels (False, False) terug en worden hieronder
    # op dezelfde manier uit de lijst gefilterd.
    _PROBE_LIMIT = 20
    to_probe = with_url[:_PROBE_LIMIT]
    checks = await asyncio.gather(
        *[_probe_subtitle_langs((c.get("url") or "").strip()) for c in to_probe],
        return_exceptions=True,
    )
    probed_by_id: dict[int, tuple[bool, bool]] = {}
    for item, r in zip(to_probe, checks):
        if isinstance(r, Exception):
            continue
        _ok, has_nl, has_en = r
        probed_by_id[id(item)] = (has_nl, has_en)

    sources = []
    for item in with_url:
        raw_url = (item.get("url") or "").strip()
        if not raw_url:
            continue

        # Enkel bevestigd werkende bronnen met NL of EN ondertitels tonen -
        # geen ongecheckte gok-resultaten die achteraf "unavailable" blijken.
        probed = probed_by_id.get(id(item))
        if probed is None:
            continue
        has_nl, has_en = probed
        if not has_nl and not has_en:
            continue

        not_ready = bool(item.get("notWebReady"))
        if not_ready or raw_url.startswith("magnet:"):
            picked_value = f"/api/stream/play?url={urllib.parse.quote(raw_url, safe='')}"
        else:
            picked_value = raw_url
        picked_value = picked_value.replace(":8086", ":3003")

        name = item.get("name") or item.get("filename") or q
        resolution = ((item.get("parsedFile") or {}).get("resolution")) or ""
        try:
            size_bytes = int(item.get("size") or 0)
        except Exception:
            size_bytes = 0

        sources.append({
            "title": str(name)[:500],
            "resolution": str(resolution),
            "size_bytes": size_bytes,
            "cached": bool(item.get("cached")),
            "has_nl_subs": has_nl,
            "has_en_subs": has_en,
            "stream_url": f"/api/stream/play?url={urllib.parse.quote(picked_value, safe='')}",
            "direct_url": picked_value,
        })

    # Bevestigde NL-ondertitels eerst, dan bevestigd EN, dan ongecheckte.
    def _sort_key(s):
        if s["has_nl_subs"] is True:
            return 0
        if s["has_en_subs"] is True:
            return 1
        return 2
    sources.sort(key=_sort_key)

    return {"sources": sources}


@router.post("/add")
async def add_magnet(body: MagnetRequest):
    """Voegt een magnet toe aan Real-Debrid en selecteert automatisch alle bestanden."""
    async with httpx.AsyncClient() as client:
        # Stap 1: magnet toevoegen
        r = await client.post(
            f"{RD_BASE}/torrents/addMagnet",
            headers=rd_headers(),
            data={"magnet": body.magnet}
        )
        r.raise_for_status()
        torrent_id = r.json()["id"]

        # Stap 2: alle bestanden selecteren
        await client.post(
            f"{RD_BASE}/torrents/selectFiles/{torrent_id}",
            headers=rd_headers(),
            data={"files": "all"}
        )

    return {"torrent_id": torrent_id}


@router.get("/links/{torrent_id}")
async def get_links(torrent_id: str):
    """Haalt de download links op voor een toegevoegde torrent."""
    async with httpx.AsyncClient() as client:
        r = await client.get(
            f"{RD_BASE}/torrents/info/{torrent_id}",
            headers=rd_headers()
        )
        r.raise_for_status()
        info = r.json()

    return {"status": info.get("status"), "links": info.get("links", [])}
