import httpx
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from .config_loader import get_seerr_config

router = APIRouter()

STATUS_LABELS = {
    1: "Onbekend",
    2: "Aangevraagd",
    3: "Beschikbaar",
    4: "Gedeeltelijk beschikbaar",
    5: "Verwerken",
}


class RequestBody(BaseModel):
    media_id: int
    media_type: str # "movie" of "tv"
    seasons: list[int] = [] # Alleen voor tv


def _find_first_request_id(data):
    if isinstance(data, dict):
        if isinstance(data.get("requestId"), int):
            return data.get("requestId")
        if isinstance(data.get("id"), int) and ("requestedBy" in data or "createdAt" in data):
            return data.get("id")
        for v in data.values():
            rid = _find_first_request_id(v)
            if rid is not None:
                return rid
    elif isinstance(data, list):
        for it in data:
            rid = _find_first_request_id(it)
            if rid is not None:
                return rid
    return None


def _has_request_for_seasons(data, seasons: list[int]) -> bool:
    if not seasons:
        return True
    if not isinstance(data, dict):
        return False
    requests = data.get("requests")
    if not isinstance(requests, list):
        return False
    for r in requests:
        if not isinstance(r, dict):
            continue
        rs = r.get("seasons")
        if isinstance(rs, list) and any(isinstance(x, int) and x in seasons for x in rs):
            return True
    return False


@router.get("/status")
async def test_seerr():
    config = get_seerr_config()
    url = config.get("url")
    key = config.get("api_key")
    
    if not url or not key:
        return {"ok": False, "message": "Seerr URL of API key niet ingesteld in .env."}
    
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                f"{url}/api/v1/settings/main",
                headers={"X-Api-Key": key},
                timeout=5
            )
            if r.status_code == 200:
                return {"ok": True, "message": "Verbonden met Overseerr/Jellyseerr."}
            elif r.status_code in (401, 403):
                return {"ok": False, "message": f"Toegang geweigerd (status {r.status_code}). Controleer je Seerr API key in .env."}
            else:
                return {"ok": False, "message": f"Seerr gaf status {r.status_code} terug."}
    except Exception as e:
        return {"ok": False, "message": f"Verbindingsfout: {str(e)}"}

@router.post("/request")
async def request_media(body: RequestBody):
    config = get_seerr_config()
    url = config.get("url")
    key = config.get("api_key")
    
    if not url or not key:
        raise HTTPException(status_code=400, detail="Seerr niet geconfigureerd.")

    try:
        async with httpx.AsyncClient() as client:
            existing = await client.get(
                f"{url}/api/v1/media/tmdb/{body.media_id}",
                headers={"X-Api-Key": key},
                timeout=10
            )

        if existing.status_code == 200:
            existing_data = existing.json()
            existing_request_id = _find_first_request_id(existing_data)
            if body.media_type == "movie":
                return {
                    "ok": True,
                    "message": "Bestaat al in Seerr.",
                    "request_id": existing_request_id,
                    "media": existing_data,
                }
            if body.media_type == "tv" and _has_request_for_seasons(existing_data, body.seasons):
                return {
                    "ok": True,
                    "message": "Bestaat al in Seerr.",
                    "request_id": existing_request_id,
                    "media": existing_data,
                }

        if existing.status_code in (401, 403):
            return {"ok": False, "message": f"Seerr fout: {existing.status_code}. Toegang geweigerd."}
    except Exception:
        pass
    
    endpoint = f"{url}/api/v1/request"
    payload = {
        "mediaId": body.media_id,
        "mediaType": body.media_type,
    }
    
    if body.media_type == "tv" and body.seasons:
        payload["seasons"] = body.seasons
        # To support future seasons in Seerr, we need to pass isAllSeasons if possible.
        # But generally Seerr accepts "seasons": "all" or we just provide the list. 
        # If we provide all existing seasons, Sonarr usually monitors future ones depending on Seerr settings.
        # We can also add "isAllSeasons": True if the user selected all seasons (which we pass from frontend).
        # We'll just pass the seasons array, which works out of the box for existing ones.
        # To be safe and let Seerr handle new seasons:
        if len(body.seasons) > 1: # if we pass multiple, it's likely "all seasons"
            payload["isAllSeasons"] = True

    try:
        async with httpx.AsyncClient() as client:
            r = await client.post(
                endpoint,
                headers={"X-Api-Key": key},
                json=payload,
                timeout=10
            )
            if r.status_code in [200, 201]:
                data = r.json()
                return {
                    "ok": True,
                    "message": "Verzoek succesvol ingediend bij Seerr.",
                    "request_id": data.get("id"),
                    "media": data.get("media"),
                }
            else:
                try:
                    data = r.json()
                    err_msg = data.get("message")
                except:
                    err_msg = None
                
                if not err_msg:
                    if r.status_code == 403:
                        err_msg = "Seerr fout: 403. Controleer of de gebruiker van de API Key voldoende rechten heeft in Seerr."
                    elif r.status_code == 401:
                        err_msg = "Seerr fout: 401. API Key is ongeldig. Controleer .env."
                    else:
                        err_msg = f"Seerr fout: {r.status_code}"
                
                return {"ok": False, "message": err_msg}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Fout bij verbinden met Seerr: {str(e)}")


@router.get("/request/{request_id}")
async def get_request(request_id: int):
    config = get_seerr_config()
    url = config.get("url")
    key = config.get("api_key")

    if not url or not key:
        raise HTTPException(status_code=400, detail="Seerr niet geconfigureerd.")

    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                f"{url}/api/v1/request/{request_id}",
                headers={"X-Api-Key": key},
                timeout=10
            )
        if r.status_code == 200:
            return {"ok": True, "request": r.json()}
        return {"ok": False, "message": f"Seerr gaf status {r.status_code} terug."}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Fout bij verbinden met Seerr: {str(e)}")


@router.get("/media-status")
async def media_status(tmdb_id: int, media_type: str):
    config = get_seerr_config()
    url = config.get("url")
    key = config.get("api_key")

    if not url or not key:
        return {"ok": False, "message": "Seerr niet geconfigureerd."}

    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                f"{url}/api/v1/media/tmdb/{tmdb_id}",
                headers={"X-Api-Key": key},
                timeout=10
            )
        if r.status_code == 200:
            data = r.json()
            status_code = data.get("status")
            status_label = STATUS_LABELS.get(status_code, f"Status {status_code}")
            return {
                "ok": True,
                "status": status_code,
                "status_label": status_label,
                "download_status": data.get("downloadStatus") or data.get("downloadStatus4k"),
                "media": data,
            }
        if r.status_code == 404:
            return {"ok": True, "status": None, "status_label": "Niet aangevraagd", "media": None}
        return {"ok": False, "message": f"Seerr gaf status {r.status_code} terug."}
    except Exception as e:
        return {"ok": False, "message": f"Fout bij verbinden met Seerr: {str(e)}"}
