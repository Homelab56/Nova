import os
import json
import httpx
from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter()

CONFIG_FILE = "/app/data/config.json"


def load_config() -> dict:
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            return json.load(f)
    return {
        "tmdb_api_key": "",
        "rd_api_token": "",
        "jackett_url": "",
        "jackett_api_key": "",
        "aio_streams_url": "",
        "aio_streams_user": "",
        "aio_streams_password": "",
        "aio_streams_user_data_b64": "",
    }


def save_config(config: dict):
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=2)


class Config(BaseModel):
    tmdb_api_key: str = ""
    rd_api_token: str = ""
    jackett_url: str = ""
    jackett_api_key: str = ""
    media_path: str = "/mnt/debrid"
    aio_streams_url: str = ""
    aio_streams_user: str = ""
    aio_streams_password: str = ""
    aio_streams_user_data_b64: str = ""


@router.get("/test/media")
async def test_media():
    # In de container is het ALTIJD /media, ongeacht wat MEDIA_PATH op de host is
    path = "/media"
    if not os.path.exists(path):
        return {"ok": False, "message": "Pad /media niet gevonden in container. Controleer je volumes in docker-compose.yml."}
    
    try:
        # Check of we iets kunnen lezen
        items = os.listdir(path)
        return {"ok": True, "message": f"Verbonden met mount. Bevat {len(items)} mappen/bestanden."}
    except Exception as e:
        return {"ok": False, "message": f"Fout bij lezen van /media: {str(e)}"}


async def test_aiostreams():
    from .config_loader import get_aiostreams_config
    import base64 as _b64

    cfg = get_aiostreams_config()
    base = (cfg.get("base_url") or "").rstrip("/")
    if not base:
        return {"ok": False, "message": "Geen AIOStreams-URL. Zet AIOSTREAMS_URL in .env (bijv. http://192.168.1.75:3003)."}

    headers: dict[str, str] = {}
    b64_ud = (cfg.get("user_data_b64") or "").strip()
    if b64_ud:
        headers["x-aiostreams-user-data"] = b64_ud
    else:
        user = (cfg.get("username") or "").strip()
        password = (cfg.get("password") or "").strip()
        if user and password:
            token = _b64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
            headers["Authorization"] = f"Basic {token}"

    try:
        async with httpx.AsyncClient(timeout=12) as client:
            r = await client.get(
                f"{base}/api/v1/search",
                params={"type": "movie", "id": "tmdb:550", "format": "false"},
                headers=headers,
            )
    except Exception as e:
        return {"ok": False, "message": f"Geen verbinding met AIOStreams: {e}"}

    if r.status_code == 401:
        return {
            "ok": False,
            "message": "Authenticatie mislukt. Vul AIOSTREAMS_USER en AIOSTREAMS_PASSWORD of AIOSTREAMS_USER_DATA_B64 in.",
        }

    try:
        data = r.json()
    except Exception:
        return {"ok": False, "message": "Ongeldig antwoord van AIOStreams."}

    if data.get("success"):
        return {"ok": True, "message": f"AIOStreams bereikbaar op {base}."}
    err = (data.get("error") or {}).get("message") or r.text[:200]
    return {"ok": False, "message": f"AIOStreams: {err}"}


@router.get("/status")
async def get_all_status():
    tmdb = await test_tmdb()
    rd = await test_rd()
    jackett = await test_jackett()
    media = await test_media()
    aiostreams = await test_aiostreams()

    from .seerr import test_seerr
    seerr = await test_seerr()

    return {
        "tmdb": tmdb,
        "rd": rd,
        "jackett": jackett,
        "media": media,
        "aiostreams": aiostreams,
        "seerr": seerr,
    }


@router.get("/")
def get_settings():
    config = load_config()
    aio_url = (config.get("aio_streams_url") or os.getenv("AIOSTREAMS_URL", "")).strip()
    return {
        "tmdb_api_key": config.get("tmdb_api_key", ""),
        "rd_api_token": config.get("rd_api_token", ""),
        "jackett_url": config.get("jackett_url", ""),
        "jackett_api_key": config.get("jackett_api_key", ""),
        "media_path": config.get("media_path", os.getenv("MEDIA_PATH", "/mnt/debrid")),
        "aio_streams_url": config.get("aio_streams_url", ""),
        "aio_streams_user": config.get("aio_streams_user", ""),
        "aio_streams_password": config.get("aio_streams_password", ""),
        "aio_streams_user_data_b64": config.get("aio_streams_user_data_b64", ""),
        "tmdb_configured": bool(config.get("tmdb_api_key")),
        "rd_configured": bool(config.get("rd_api_token")),
        "jackett_configured": bool(config.get("jackett_url") and config.get("jackett_api_key")),
        "aio_streams_configured": bool(aio_url),
    }


@router.post("/")
def save_settings(body: Config):
    config = load_config()
    if body.tmdb_api_key:
        config["tmdb_api_key"] = body.tmdb_api_key
    if body.rd_api_token:
        config["rd_api_token"] = body.rd_api_token
    if body.jackett_url:
        config["jackett_url"] = body.jackett_url
    if body.jackett_api_key:
        config["jackett_api_key"] = body.jackett_api_key
    if body.media_path:
        config["media_path"] = body.media_path
    if body.aio_streams_url:
        config["aio_streams_url"] = body.aio_streams_url.strip()
    if body.aio_streams_user:
        config["aio_streams_user"] = body.aio_streams_user.strip()
    if body.aio_streams_password:
        config["aio_streams_password"] = body.aio_streams_password.strip()
    if body.aio_streams_user_data_b64:
        config["aio_streams_user_data_b64"] = body.aio_streams_user_data_b64.strip()
    save_config(config)
    return {"ok": True}


@router.get("/test/tmdb")
async def test_tmdb():
    config = load_config()
    key = config.get("tmdb_api_key") or os.getenv("TMDB_API_KEY", "")
    
    if not key or "jouw_tmdb" in key:
        return {"ok": False, "message": "Geen TMDB API key ingevuld in .env."}
    
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                "https://api.themoviedb.org/3/configuration",
                params={"api_key": key},
                timeout=5,
            )
        if r.status_code == 200:
            return {"ok": True, "message": "TMDB verbinding werkt."}
        elif r.status_code == 401:
            return {"ok": False, "message": "Ongeldige TMDB API key. Controleer .env."}
        else:
            return {"ok": False, "message": f"TMDB gaf status {r.status_code} terug."}
    except Exception as e:
        return {"ok": False, "message": f"Verbindingsfout: {str(e)}"}


@router.get("/test/jackett")
async def test_jackett():
    from .config_loader import get_jackett_config
    config = get_jackett_config()
    url = config.get("url")
    key = config.get("api_key")
    
    if not url or not key or "jouw_prowlarr" in url:
        return {"ok": False, "message": "Geen Prowlarr/Jackett URL of API key gevonden in .env."}
    
    try:
        # We proberen de basis URL te testen om te zien of Prowlarr/Jackett reageert
        # Voor Prowlarr is de API meestal op /api/v1/...
        # Voor Jackett is het /api/v2.0/...
        # We proberen een algemene endpoint die op beide zou moeten werken of in ieder geval een 200/401 geeft
        
        async with httpx.AsyncClient() as client:
            # Probeer eerst de Prowlarr status endpoint
            prowlarr_test = await client.get(
                f"{url.rstrip('/')}/api/v1/system/status",
                params={"apikey": key},
                timeout=5,
            )
            if prowlarr_test.status_code == 200:
                return {"ok": True, "message": "Verbonden met Prowlarr."}

            # Als dat niet werkt, probeer de Torznab caps (Jackett stijl)
            r = await client.get(
                f"{url.rstrip('/')}/api/v2.0/indexers/all/results/torznab/api",
                params={"apikey": key, "t": "caps"},
                timeout=5,
            )
            if r.status_code == 200:
                return {"ok": True, "message": "Verbonden met Prowlarr/Jackett (Torznab)."}
            elif r.status_code in (401, 403):
                return {"ok": False, "message": f"Toegang geweigerd (status {r.status_code}). Controleer je API key in .env voor {url}"}
            else:
                return {"ok": False, "message": f"Indexer gaf status {r.status_code} terug op {url}"}
    except Exception as e:
        return {"ok": False, "message": f"Verbindingsfout: {str(e)}"}


@router.get("/test/rd")
async def test_rd():
    config = load_config()
    token = config.get("rd_api_token") or os.getenv("RD_API_TOKEN", "")
    
    if not token or "jouw_realdebrid" in token:
        return {"ok": False, "message": "Geen Real-Debrid token ingevuld in .env."}
    
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                "https://api.real-debrid.com/rest/1.0/user",
                headers={"Authorization": f"Bearer {token}"},
                timeout=5,
            )
        if r.status_code == 200:
            data = r.json()
            premium_seconds = data.get("premium", 0)
            premium_days = premium_seconds // 86400
            return {
                "ok": True,
                "message": f"Verbonden als {data.get('username')}. "
                           f"Premium nog {premium_days} dagen geldig.",
            }
        elif r.status_code == 401:
            return {"ok": False, "message": "Ongeldige Real-Debrid token. Controleer .env."}
        else:
            return {"ok": False, "message": f"Real-Debrid gaf status {r.status_code} terug."}
    except Exception as e:
        return {"ok": False, "message": f"Verbindingsfout: {str(e)}"}
