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


def get_opensubtitles_key() -> str:
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            data = json.load(f)
        key = data.get("opensubtitles_api_key", "")
        if key:
            return key
    return os.getenv("OPENSUBTITLES_API_KEY", "").strip().replace("`", "")


def get_opensubtitles_credentials() -> tuple[str, str]:
    """VIP-quota (hogere daglimiet dan de anonieme API-key alleen geeft) is
    gekoppeld aan het account, niet aan de API-key - hiervoor moet dus
    ingelogd worden."""
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            data = json.load(f)
        user = data.get("opensubtitles_username", "")
        pw = data.get("opensubtitles_password", "")
        if user and pw:
            return user, pw
    return (
        os.getenv("OPENSUBTITLES_USERNAME", "").strip(),
        os.getenv("OPENSUBTITLES_PASSWORD", "").strip(),
    )


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


def get_aiostreams_stremio_addon_url() -> str:
    """Volledige Stremio-protocol addon-basis-URL van AIOStreams (dus met het
    /stremio/<user>/<config>-pad, niet de kale /api/v1/... basis-URL hierboven)
    - gebruikt als server-side fallback om een referentiestream te vinden voor
    ffsubsync wanneer Nova's eigen (smallere) zoeklogica niets vindt maar
    AIOStreams' eigen, veel bredere aggregatie wel iets zou vinden."""
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            data = json.load(f)
        url = (data.get("aiostreams_addon_url") or "").strip().replace("`", "").rstrip("/")
        if url:
            return url
    return os.getenv("AIOSTREAMS_ADDON_URL", "").strip().replace("`", "").rstrip("/")


def get_aiostreams_config() -> dict:
    """AIOStreams (Stremio-aggregator) basis-URL en optionele auth."""
    url = ""
    user = ""
    password = ""
    user_data_b64 = ""
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            data = json.load(f)
        url = (data.get("aio_streams_url") or "").strip().replace("`", "").rstrip("/")
        user = (data.get("aio_streams_user") or "").strip().replace("`", "")
        password = (data.get("aio_streams_password") or "").strip().replace("`", "")
        user_data_b64 = (data.get("aio_streams_user_data_b64") or "").strip().replace("`", "")

    url = url or os.getenv("AIOSTREAMS_URL", "").strip().replace("`", "").rstrip("/")
    user = user or os.getenv("AIOSTREAMS_USER", "").strip().replace("`", "")
    password = password or os.getenv("AIOSTREAMS_PASSWORD", "").strip().replace("`", "")
    user_data_b64 = user_data_b64 or os.getenv("AIOSTREAMS_USER_DATA_B64", "").strip().replace("`", "")

    return {
        "base_url": url,
        "username": user,
        "password": password,
        "user_data_b64": user_data_b64,
    }
