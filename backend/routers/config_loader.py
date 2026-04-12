import os
import json

CONFIG_FILE = "/app/data/config.json"


def get_tmdb_key() -> str:
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            data = json.load(f)
        key = data.get("tmdb_api_key", "")
        if key:
            return key
    return os.getenv("TMDB_API_KEY", "")


def get_rd_token() -> str:
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            data = json.load(f)
        token = data.get("rd_api_token", "")
        if token:
            return token
    return os.getenv("RD_API_TOKEN", "")


def get_jackett_config() -> dict:
    """Haalt Jackett of Prowlarr URL en API key op uit config of env."""
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            data = json.load(f)
        url = data.get("jackett_url", "")
        key = data.get("jackett_api_key", "")
        if url and key:
            return {"url": url, "api_key": key}
    
    # Check eerst PROWLARR_ env vars, dan JACKETT_
    url = os.getenv("PROWLARR_URL") or os.getenv("JACKETT_URL", "")
    key = os.getenv("PROWLARR_API_KEY") or os.getenv("JACKETT_API_KEY", "")
    
    # Verwijder eventuele spaties of backticks die de gebruiker per ongeluk heeft toegevoegd
    url = url.strip().replace("`", "").rstrip("/")
    key = key.strip().replace("`", "")
    
    return {
        "url": url,
        "api_key": key
    }


def get_seerr_config() -> dict:
    """Haalt Overseerr/Jellyseerr URL en API key op uit config of env."""
    url = os.getenv("SEERR_URL", "").strip().replace("`", "").rstrip("/")
    key = os.getenv("SEERR_API_KEY", "").strip().replace("`", "")
    return {"url": url, "api_key": key}
