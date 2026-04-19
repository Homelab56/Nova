import httpx
from fastapi import APIRouter, Query
from .config_loader import get_tmdb_key

router = APIRouter()
TMDB_BASE = "https://api.themoviedb.org/3"

# Genre IDs
GENRE_ROWS = [
    {"id": 28,    "name": "Actie"},
    {"id": 35,    "name": "Komedie"},
    {"id": 27,    "name": "Horror"},
    {"id": 12,    "name": "Avontuur"},
    {"id": 878,   "name": "Sci-Fi"},
    {"id": 18,    "name": "Drama"},
    {"id": 53,    "name": "Thriller"},
    {"id": 16,    "name": "Animatie"},
    {"id": 10749, "name": "Romantiek"},
    {"id": 99,    "name": "Documentaire"},
    {"id": 14,    "name": "Fantasy"},
    {"id": 9648,  "name": "Mystery"},
]

EXCLUDE_TV_GENRES = {10763, 10764, 10766, 10767}
KIDS_MOVIE_GENRES = {10751}
KIDS_TV_GENRES = {10762, 10751}


async def tmdb_get(path: str, params: dict = {}):
    p = dict(params)
    p["api_key"] = get_tmdb_key()
    p["language"] = "nl-NL"
    p.setdefault("include_adult", "false")
    async with httpx.AsyncClient() as client:
        r = await client.get(f"{TMDB_BASE}{path}", params=p)
        r.raise_for_status()
        return r.json()

def _as_int_set(values) -> set[int]:
    if not isinstance(values, list):
        return set()
    out = set()
    for v in values:
        try:
            out.add(int(v))
        except Exception:
            continue
    return out

def _is_anime(item: dict, media_type: str | None) -> bool:
    if not isinstance(item, dict):
        return False
    genres = _as_int_set(item.get("genre_ids"))
    if 16 not in genres:
        return False
    if item.get("original_language") == "ja":
        return True
    if media_type == "tv":
        origin = item.get("origin_country")
        if isinstance(origin, list) and "JP" in origin:
            return True
    return False

def _is_kids(item: dict, media_type: str | None) -> bool:
    if not isinstance(item, dict):
        return False
    genres = _as_int_set(item.get("genre_ids"))
    if media_type == "tv":
        return len(genres & KIDS_TV_GENRES) > 0
    if media_type == "movie":
        return len(genres & KIDS_MOVIE_GENRES) > 0
    return len(genres & (KIDS_MOVIE_GENRES | KIDS_TV_GENRES)) > 0

def _is_weird_tv(item: dict) -> bool:
    genres = _as_int_set(item.get("genre_ids"))
    return len(genres & EXCLUDE_TV_GENRES) > 0

def _tag_media_type(items: list[dict], media_type: str | None) -> list[dict]:
    if not media_type:
        return items
    out = []
    for it in items:
        if not isinstance(it, dict):
            continue
        if "media_type" not in it:
            it = dict(it)
            it["media_type"] = media_type
        out.append(it)
    return out

def _filter_items(
    items: list[dict],
    media_type: str | None,
    suggestion_mode: bool,
    allow_kids: bool,
) -> list[dict]:
    out = []
    for it in items or []:
        if not isinstance(it, dict):
            continue
        if it.get("adult") is True:
            continue
        inferred = it.get("media_type") or media_type
        if _is_anime(it, inferred):
            continue
        if suggestion_mode and inferred == "tv" and _is_weird_tv(it):
            continue
        if suggestion_mode and not allow_kids and _is_kids(it, inferred):
            continue
        out.append(it)
    return out

async def tmdb_list(
    path: str,
    page: int = 1,
    params: dict = {},
    prefetch_pages: int = 5,
    media_type: str | None = None,
    suggestion_mode: bool = True,
    allow_kids: bool = False,
):
    import asyncio
    base_params = dict(params)
    if page <= 1:
        first = await tmdb_get(path, {**base_params, "page": 1})
        total_pages = int(first.get("total_pages") or 1)
        total_results = int(first.get("total_results") or 0)
        max_page = max(1, min(prefetch_pages, total_pages))
        pages = [first]
        if max_page > 1:
            pages.extend(
                await asyncio.gather(
                    *[tmdb_get(path, {**base_params, "page": p}) for p in range(2, max_page + 1)]
                )
            )
        items, seen = [], set()
        for data in pages:
            for it in data.get("results", []) or []:
                it_id = it.get("id")
                if it_id is None or it_id in seen:
                    continue
                seen.add(it_id)
                items.append(it)
        items = _tag_media_type(items, media_type)
        items = _filter_items(items, media_type=media_type, suggestion_mode=suggestion_mode, allow_kids=allow_kids)
        return {"items": items, "page": max_page, "total_pages": total_pages, "total_results": total_results}

    data = await tmdb_get(path, {**base_params, "page": page})
    items = _tag_media_type(data.get("results", []) or [], media_type)
    items = _filter_items(items, media_type=media_type, suggestion_mode=suggestion_mode, allow_kids=allow_kids)
    return {
        "items": items,
        "page": page,
        "total_pages": int(data.get("total_pages") or 1),
        "total_results": int(data.get("total_results") or 0),
    }


# --- Trending & Popular ---

@router.get("/trending")
async def trending(page: int = 1):
    return await tmdb_list("/trending/all/week", page=page, prefetch_pages=5, media_type=None, suggestion_mode=True, allow_kids=False)

@router.get("/trending/movies")
async def trending_movies(page: int = 1):
    return await tmdb_list("/trending/movie/week", page=page, prefetch_pages=5, media_type="movie", suggestion_mode=True, allow_kids=False)

@router.get("/trending/tv")
async def trending_tv(page: int = 1):
    return await tmdb_list("/trending/tv/week", page=page, prefetch_pages=5, media_type="tv", suggestion_mode=True, allow_kids=False)

@router.get("/popular/movies")
async def popular_movies(page: int = 1):
    return await tmdb_list("/movie/popular", page=page, prefetch_pages=5, media_type="movie", suggestion_mode=True, allow_kids=False)

@router.get("/popular/tv")
async def popular_tv(page: int = 1):
    return await tmdb_list("/tv/popular", page=page, prefetch_pages=5, media_type="tv", suggestion_mode=True, allow_kids=False)

@router.get("/toprated/movies")
async def toprated_movies(page: int = 1):
    return await tmdb_list("/movie/top_rated", page=page, prefetch_pages=5, media_type="movie", suggestion_mode=True, allow_kids=False)

@router.get("/toprated/tv")
async def toprated_tv(page: int = 1):
    return await tmdb_list("/tv/top_rated", page=page, prefetch_pages=5, media_type="tv", suggestion_mode=True, allow_kids=False)

@router.get("/nowplaying/movies")
async def nowplaying_movies(page: int = 1):
    return await tmdb_list("/movie/now_playing", page=page, prefetch_pages=5, media_type="movie", suggestion_mode=True, allow_kids=False)

@router.get("/upcoming/movies")
async def upcoming_movies(page: int = 1):
    return await tmdb_list("/movie/upcoming", page=page, prefetch_pages=5, media_type="movie", suggestion_mode=True, allow_kids=False)

@router.get("/onair/tv")
async def onair_tv(page: int = 1):
    return await tmdb_list("/tv/on_the_air", page=page, prefetch_pages=5, media_type="tv", suggestion_mode=True, allow_kids=False)

@router.get("/airingtoday/tv")
async def airingtoday_tv(page: int = 1):
    return await tmdb_list("/tv/airing_today", page=page, prefetch_pages=5, media_type="tv", suggestion_mode=True, allow_kids=False)


@router.get("/kids/movies")
async def kids_movies(page: int = 1):
    return await tmdb_list(
        "/discover/movie",
        page=page,
        params={"sort_by": "popularity.desc", "with_genres": "10751", "vote_count.gte": 25},
        prefetch_pages=5,
        media_type="movie",
        suggestion_mode=True,
        allow_kids=True,
    )

@router.get("/kids/tv")
async def kids_tv(page: int = 1):
    return await tmdb_list(
        "/discover/tv",
        page=page,
        params={"sort_by": "popularity.desc", "with_genres": "10762|10751", "vote_count.gte": 25},
        prefetch_pages=5,
        media_type="tv",
        suggestion_mode=True,
        allow_kids=True,
    )


# --- Genre discover ---

@router.get("/genre/{genre_id}")
async def by_genre(genre_id: int, type: str = "movie", page: int = 1):
    import asyncio
    if page == 1:
        tasks = [
            tmdb_get(f"/discover/{type}", {"with_genres": genre_id, "sort_by": "popularity.desc", "page": p, "include_adult": "false"})
            for p in range(1, 6)
        ]
        pages = await asyncio.gather(*tasks)
        items, seen = [], set()
        for pg in pages:
            for item in pg.get("results", []):
                if item["id"] not in seen:
                    seen.add(item["id"])
                    items.append(item)
        first = pages[0]
        return {
            "items": _filter_items(_tag_media_type(items, type), media_type=type, suggestion_mode=False, allow_kids=True),
            "page": 5,
            "total_pages": first.get("total_pages", 1),
            "total_results": first.get("total_results", 0),
        }
    data = await tmdb_get(f"/discover/{type}", {
        "with_genres": genre_id,
        "sort_by": "popularity.desc",
        "page": page,
        "include_adult": "false",
    })
    return {
        "items": _filter_items(_tag_media_type(data.get("results", []) or [], type), media_type=type, suggestion_mode=False, allow_kids=True),
        "page": page,
        "total_pages": data.get("total_pages", 1),
        "total_results": data.get("total_results", 0),
    }

@router.get("/genre-rows")
async def genre_rows(type: str = "all"):
    """Geeft voor elk genre een rij terug. type = all | movie | tv"""
    import asyncio
    media_types = ["movie", "tv"] if type == "all" else [type]

    async def fetch_genre(genre, mtype):
        import asyncio
        first = await tmdb_get(
            f"/discover/{mtype}",
            {"with_genres": genre["id"], "sort_by": "popularity.desc", "page": 1, "include_adult": "false"},
        )
        total_pages = int(first.get("total_pages") or 1)
        max_page = max(1, min(3, total_pages))
        pages = [first]
        if max_page > 1:
            pages.extend(
                await asyncio.gather(
                    *[
                        tmdb_get(
                            f"/discover/{mtype}",
                            {"with_genres": genre["id"], "sort_by": "popularity.desc", "page": p, "include_adult": "false"},
                        )
                        for p in range(2, max_page + 1)
                    ]
                )
            )
        items, seen = [], set()
        for page in pages:
            for item in page.get("results", []):
                if item["id"] not in seen:
                    seen.add(item["id"])
                    items.append(item)
        items = _tag_media_type(items, mtype)
        items = _filter_items(items, media_type=mtype, suggestion_mode=True, allow_kids=False)
        suffix = "" if type != "all" else (" — Films" if mtype == "movie" else " — Series")
        return {
            "key": f"genre_{genre['id']}_{mtype}",
            "genre_id": int(genre["id"]),
            "media_type": mtype,
            "title": genre["name"] + suffix,
            "items": items,
            "page": max_page,
            "total_pages": total_pages,
        }

    tasks = [fetch_genre(g, mt) for g in GENRE_ROWS for mt in media_types]
    results = await asyncio.gather(*tasks)
    # Filter lege rijen weg
    return [r for r in results if len(r["items"]) > 0]


# --- Zoeken ---

@router.get("/movie")
async def search_movies(q: str = Query(..., min_length=1), page: int = 1):
    import asyncio
    if page == 1:
        # Eerste load: 5 pagina's tegelijk = ~100 resultaten
        tasks = [tmdb_get("/search/movie", {"query": q, "page": p, "include_adult": "false"}) for p in range(1, 6)]
        pages = await asyncio.gather(*tasks)
        items, seen = [], set()
        for pg in pages:
            for item in pg.get("results", []):
                if item["id"] not in seen:
                    seen.add(item["id"])
                    items.append(item)
        first = pages[0]
        return {
            "items": _filter_items(_tag_media_type(items, "movie"), media_type="movie", suggestion_mode=False, allow_kids=True),
            "page": 5,
            "total_pages": first.get("total_pages", 1),
            "total_results": first.get("total_results", 0),
        }
    data = await tmdb_get("/search/movie", {"query": q, "page": page, "include_adult": "false"})
    return {
        "items": _filter_items(_tag_media_type(data.get("results", []) or [], "movie"), media_type="movie", suggestion_mode=False, allow_kids=True),
        "page": page,
        "total_pages": data.get("total_pages", 1),
        "total_results": data.get("total_results", 0),
    }

@router.get("/tv")
async def search_tv(q: str = Query(..., min_length=1), page: int = 1):
    import asyncio
    if page == 1:
        tasks = [tmdb_get("/search/tv", {"query": q, "page": p, "include_adult": "false"}) for p in range(1, 6)]
        pages = await asyncio.gather(*tasks)
        items, seen = [], set()
        for pg in pages:
            for item in pg.get("results", []):
                if item["id"] not in seen:
                    seen.add(item["id"])
                    items.append(item)
        first = pages[0]
        return {
            "items": _filter_items(_tag_media_type(items, "tv"), media_type="tv", suggestion_mode=False, allow_kids=True),
            "page": 5,
            "total_pages": first.get("total_pages", 1),
            "total_results": first.get("total_results", 0),
        }
    data = await tmdb_get("/search/tv", {"query": q, "page": page, "include_adult": "false"})
    return {
        "items": _filter_items(_tag_media_type(data.get("results", []) or [], "tv"), media_type="tv", suggestion_mode=False, allow_kids=True),
        "page": page,
        "total_pages": data.get("total_pages", 1),
        "total_results": data.get("total_results", 0),
    }


# --- Detail ---

@router.get("/movie/{tmdb_id}")
async def movie_detail(tmdb_id: int):
    return await tmdb_get(f"/movie/{tmdb_id}")

@router.get("/movie/{tmdb_id}/credits")
async def movie_credits(tmdb_id: int):
    data = await tmdb_get(f"/movie/{tmdb_id}/credits")
    return data.get("cast", [])[:12]

@router.get("/movie/{tmdb_id}/similar")
async def movie_similar(tmdb_id: int):
    data = await tmdb_get(f"/movie/{tmdb_id}/similar")
    return data.get("results", [])[:18]

@router.get("/tv/{tmdb_id}")
async def tv_detail(tmdb_id: int):
    return await tmdb_get(f"/tv/{tmdb_id}")

@router.get("/tv/{tmdb_id}/credits")
async def tv_credits(tmdb_id: int):
    data = await tmdb_get(f"/tv/{tmdb_id}/credits")
    return data.get("cast", [])[:12]

@router.get("/tv/{tmdb_id}/similar")
async def tv_similar(tmdb_id: int):
    data = await tmdb_get(f"/tv/{tmdb_id}/similar")
    return data.get("results", [])[:18]

@router.get("/tv/{tmdb_id}/season/{season_number}")
async def tv_season(tmdb_id: int, season_number: int):
    return await tmdb_get(f"/tv/{tmdb_id}/season/{season_number}")
