import httpx
import os
import re
import asyncio
import urllib.parse
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from .config_loader import get_rd_token, get_tmdb_key

router = APIRouter()

RD_BASE = "https://api.real-debrid.com/rest/1.0"
TMDB_BASE = "https://api.themoviedb.org/3"


def rd_headers():
    return {"Authorization": f"Bearer {get_rd_token()}"}

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
    Checkt of een titel beschikbaar is in de RD bibliotheek zonder te unrestricten.
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

    from .library import find_file
    # GEACTIVEERD: Geen lokale checks meer om crashes te voorkomen
    return {"available": False}


# Een globale lock om te voorkomen dat de server bezwijkt onder te veel zoekopdrachten
SEARCH_SEMAPHORE = asyncio.Semaphore(2)

@router.get("/search")
async def search_and_stream(q: str, tmdb_id: int | None = None, media_type: str | None = None, client_id: str | None = None):
    """
    Zoekt automatisch naar een beschikbare stream voor een titel.
    Met semaphore om de server te beschermen tegen overbelasting.
    """
    async with SEARCH_SEMAPHORE:
        print(f"--- Start zoekopdracht voor: {q} ({media_type}) ---")
        async with httpx.AsyncClient(timeout=15) as client:
            # Stap 1: Titels bepalen (nu lichtgewicht)
            candidates = await _candidate_queries(q, tmdb_id, media_type)
            is_movie = (media_type == "movie")
            base_year = _infer_base_year(q, candidates, media_type)
            
            if is_movie and not base_year:
                print(f"Geen jaar gevonden voor film: {q}")
                return {"stream_url": None, "message": f"Geen jaar gevonden voor '{q}'."}
                
            word_sets = [(_words(c), c) for c in candidates]
            word_sets = [(w, c) for (w, c) in word_sets if w]
            if not word_sets:
                return {"stream_url": None, "message": "Ongeldige zoekopdracht."}
                
            ep_token = _episode_token(q or "") if media_type == "tv" else None
            ep_variants = None
            if ep_token:
                m = re.fullmatch(r"s(\d{2})e(\d{2})", ep_token)
                if m:
                    ss, ee = m.groups()
                    ep_variants = {ep_token, f"{int(ss)}x{int(ee):02d}", f"{int(ss):02d}x{int(ee):02d}"}

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
                                    return {
                                        "stream_url": ur.json()["download"], # Directe link voor Windows App
                                        "direct_url": ur.json()["download"],
                                        "source": "library",
                                    }
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
                return {"stream_url": None, "message": "Geen streams gevonden."}

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
                                            return {"stream_url": ur.json()["download"], "direct_url": ur.json()["download"], "source": "scraper"}
            except Exception as e:
                print(f"Cache check fout: {e}")

            print("Geen afspeelbare streams gevonden na alle stappen.")
            return {"stream_url": None, "message": "Geen direct afspeelbare streams gevonden."}


async def check_availability(magnet: str):
    """
    Checkt of een magnet link instant beschikbaar is op Real-Debrid.
    Geeft True terug als je hem direct kan streamen zonder te wachten.
    """
    # Haal de hash uit de magnet link
    hash_part = magnet.lower().split("urn:btih:")[1].split("&")[0]

    async with httpx.AsyncClient() as client:
        r = await client.get(
            f"{RD_BASE}/torrents/instantAvailability/{hash_part}",
            headers=rd_headers()
        )
        data = r.json()

    # RD geeft een geneste dict terug - als de hash erin zit is het beschikbaar
    available = bool(data.get(hash_part, {}).get("rd"))
    return {"hash": hash_part, "available": available}


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
