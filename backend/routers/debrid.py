import httpx
import os
import re
import asyncio
import urllib.parse
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from .config_loader import get_rd_token

router = APIRouter()

RD_BASE = "https://api.real-debrid.com/rest/1.0"


def rd_headers():
    return {"Authorization": f"Bearer {get_rd_token()}"}


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
async def check_availability(q: str):
    """
    Checkt of een titel beschikbaar is in de RD bibliotheek zonder te unrestricten.
    """
    async with httpx.AsyncClient() as client:
        r = await client.get(
            f"{RD_BASE}/torrents",
            headers=rd_headers(),
            params={"limit": 100}
        )
        if r.status_code != 200:
            return {"available": False}

        torrents = r.json()

    q_lower = q.lower().replace(":", "").replace("-", "")
    words = [w for w in q_lower.split() if len(w) >= 2]
    
    if not words:
        return {"available": False}

    for torrent in torrents:
        filename = torrent.get("filename", "").lower()
        score = sum(1 for word in words if word in filename)
        min_score = min(2, len(words))
        
        if score >= min_score and torrent.get("status") == "downloaded":
            return {"available": True, "filename": torrent["filename"]}

    return {"available": False}


@router.get("/search")
async def search_and_stream(q: str):
    """
    Zoekt automatisch naar een beschikbare stream voor een titel.
    1. Zoekt op de lokale Dumbarr mount (/media).
    2. Zoekt in de RD bibliotheek van de gebruiker.
    3. Zoekt via Jackett op torrent trackers.
    4. Indien Jackett niet geconfigureerd, fallback naar SolidTorrents.
    5. Controleert RD instant availability (cache) voor gevonden torrents.
    """
    q_lower = q.lower().replace(":", "").replace("-", "")
    words = [w for w in q_lower.split() if len(w) >= 2]
    
    if not words:
        return {"stream_url": None, "message": "Ongeldige zoekopdracht."}

    # --- STAP 0: Zoek op lokale Dumbarr mount ---
    from .library import find_file
    local_check = await find_file(q)
    if local_check.get("found"):
        print(f"Match gevonden op lokale mount: {local_check['path']}")
        encoded_path = urllib.parse.quote((local_check["path"] or "").replace("\\", "/"))
        return {
            "stream_url": f"/api/stream/hls?path={encoded_path}",
            "source": "local", 
            "title": os.path.basename(local_check["path"])
        }

    # --- STAP 1: Zoek in eigen RD bibliotheek ---
    async with httpx.AsyncClient() as client:
        r = await client.get(
            f"{RD_BASE}/torrents",
            headers=rd_headers(),
            params={"limit": 100}
        )
        if r.status_code == 200:
            torrents = r.json()
            best_match = None
            best_score = 0
            for torrent in torrents:
                filename = torrent.get("filename", "").lower()
                score = sum(1 for word in words if word in filename)
                min_score = min(2, len(words))
                if score >= best_score and score >= min_score:
                    if torrent.get("status") == "downloaded" and torrent.get("links"):
                        best_score = score
                        best_match = torrent

            if best_match:
                info_r = await client.get(f"{RD_BASE}/torrents/info/{best_match['id']}", headers=rd_headers())
                if info_r.status_code == 200:
                    info = info_r.json()
                    links = info.get("links", [])
                    episode_match = re.search(r"s(\d+)e(\d+)", q_lower)
                    best_file_idx = 0
                    if episode_match:
                        s, e = episode_match.groups()
                        pattern = f"s{s}e{e}"
                        for idx, f in enumerate(info.get("files", [])):
                            if pattern in f.get("path", "").lower():
                                best_file_idx = idx
                                break
                    if links and best_file_idx < len(links):
                        ur = await client.post(f"{RD_BASE}/unrestrict/link", headers=rd_headers(), data={"link": links[best_file_idx]})
                        if ur.status_code == 200:
                            download_url = ur.json().get("download")
                            if not download_url:
                                return {"stream_url": None, "message": "Geen download URL ontvangen van Real-Debrid."}
                            return {
                                "stream_url": f"/api/stream/hls?url={urllib.parse.quote(download_url)}",
                                "source": "library",
                            }

    # --- STAP 2: Zoek extern (Jackett of SolidTorrents) ---
    external_torrents = []
    
    from .config_loader import get_jackett_config
    jackett = get_jackett_config()
    
    if jackett.get("url") and jackett.get("api_key"):
        print(f"Zoeken via Jackett voor: {q}...")
        try:
            async with httpx.AsyncClient() as client:
                jr = await client.get(
                    f"{jackett['url'].rstrip('/')}/api/v2.0/indexers/all/results",
                    params={
                        "apikey": jackett["api_key"],
                        "Query": q,
                        "Category[]": [2000, 5000] # Movies & TV
                    },
                    timeout=15
                )
                if jr.status_code == 200:
                    results = jr.json().get("Results", [])
                    for res in results:
                        if res.get("InfoHash"):
                            external_torrents.append({
                                "title": res.get("Title"),
                                "hash": res.get("InfoHash"),
                                "magnet": res.get("MagnetUri"),
                                "seeders": res.get("Seeders", 0),
                                "size": res.get("Size")
                            })
        except Exception as e:
            print(f"Jackett fout: {e}")

    if not external_torrents:
        print(f"Zoeken via SolidTorrents fallback voor: {q}...")
        try:
            async with httpx.AsyncClient() as client:
                sr = await client.get(
                    "https://solidtorrents.to/api/v1/search",
                    params={"q": q, "category": "video", "sort": "seeders"},
                    timeout=10
                )
                if sr.status_code == 200:
                    results = sr.json().get("results", [])
                    for res in results:
                        external_torrents.append({
                            "title": res.get("title"),
                            "hash": res.get("infoHash"),
                            "magnet": res.get("magnet"),
                            "seeders": res.get("swarm", {}).get("seeders", 0),
                            "size": res.get("size")
                        })
        except Exception as e:
            print(f"SolidTorrents fout: {e}")

    if not external_torrents:
        # Probeer nog een keer zonder jaartal indien aanwezig
        q_no_year = re.sub(r"\s\d{4}$", "", q).strip()
        if q_no_year != q:
            return await search_and_stream(q_no_year)
        return {"stream_url": None, "message": f"Geen streams gevonden voor '{q}' op het internet."}

    # --- STAP 3: Controleer RD cache (Instant Availability) ---
    # Sorteer op de meeste seeders eerst
    external_torrents.sort(key=lambda x: x.get("seeders", 0), reverse=True)
    
    hashes = [t["hash"] for t in external_torrents[:20]] 
    if not hashes:
        return {"stream_url": None, "message": "Geen geldige torrents gevonden."}

    hash_str = "/".join(hashes)
    async with httpx.AsyncClient() as client:
        cr = await client.get(f"{RD_BASE}/torrents/instantAvailability/{hash_str}", headers=rd_headers())
        if cr.status_code == 200:
            cache_data = cr.json()
            for t in external_torrents:
                h = t["hash"].lower()
                if h in cache_data and cache_data[h].get("rd"):
                    # Gevonden in cache!
                    ar = await client.post(f"{RD_BASE}/torrents/addMagnet", headers=rd_headers(), data={"magnet": t["magnet"]})
                    if ar.status_code in [200, 201]:
                        tid = ar.json()["id"]
                        await client.post(f"{RD_BASE}/torrents/selectFiles/{tid}", headers=rd_headers(), data={"files": "all"})
                        await asyncio.sleep(1.5) # lets give RD a bit more time
                        ir = await client.get(f"{RD_BASE}/torrents/info/{tid}", headers=rd_headers())
                        if ir.status_code == 200:
                            links = ir.json().get("links", [])
                            if links:
                                ur = await client.post(f"{RD_BASE}/unrestrict/link", headers=rd_headers(), data={"link": links[0]})
                                if ur.status_code == 200:
                                    download_url = ur.json().get("download")
                                    if not download_url:
                                        return {"stream_url": None, "message": "Geen download URL ontvangen van Real-Debrid."}
                                    return {
                                        "stream_url": f"/api/stream/hls?url={urllib.parse.quote(download_url)}",
                                        "source": "scraper",
                                        "title": t["title"],
                                    }

    return {
        "stream_url": None,
        "message": f"Geen direct afspeelbare streams gevonden voor '{q}'. Probeer een andere versie of voeg handmatig een torrent toe."
    }


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
