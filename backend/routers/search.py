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


async def tmdb_get(path: str, params: dict = {}):
    p = dict(params)
    p["api_key"] = get_tmdb_key()
    p["language"] = "nl-NL"
    async with httpx.AsyncClient() as client:
        r = await client.get(f"{TMDB_BASE}{path}", params=p)
        r.raise_for_status()
        return r.json()


# --- Trending & Popular ---

@router.get("/trending")
async def trending():
    data = await tmdb_get("/trending/all/week")
    return data.get("results", [])

@router.get("/trending/movies")
async def trending_movies():
    data = await tmdb_get("/trending/movie/week")
    return data.get("results", [])

@router.get("/trending/tv")
async def trending_tv():
    data = await tmdb_get("/trending/tv/week")
    return data.get("results", [])

@router.get("/popular/movies")
async def popular_movies():
    data = await tmdb_get("/movie/popular")
    return data.get("results", [])

@router.get("/popular/tv")
async def popular_tv():
    data = await tmdb_get("/tv/popular")
    return data.get("results", [])

@router.get("/toprated/movies")
async def toprated_movies():
    data = await tmdb_get("/movie/top_rated")
    return data.get("results", [])

@router.get("/toprated/tv")
async def toprated_tv():
    data = await tmdb_get("/tv/top_rated")
    return data.get("results", [])

@router.get("/nowplaying/movies")
async def nowplaying_movies():
    data = await tmdb_get("/movie/now_playing")
    return data.get("results", [])

@router.get("/upcoming/movies")
async def upcoming_movies():
    data = await tmdb_get("/movie/upcoming")
    return data.get("results", [])

@router.get("/onair/tv")
async def onair_tv():
    data = await tmdb_get("/tv/on_the_air")
    return data.get("results", [])

@router.get("/airingtoday/tv")
async def airingtoday_tv():
    data = await tmdb_get("/tv/airing_today")
    return data.get("results", [])


# --- Genre discover ---

@router.get("/genre/{genre_id}")
async def by_genre(genre_id: int, type: str = "movie", page: int = 1):
    import asyncio
    if page == 1:
        tasks = [
            tmdb_get(f"/discover/{type}", {"with_genres": genre_id, "sort_by": "popularity.desc", "page": p})
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
            "items": items,
            "page": 5,
            "total_pages": first.get("total_pages", 1),
            "total_results": first.get("total_results", 0),
        }
    data = await tmdb_get(f"/discover/{type}", {
        "with_genres": genre_id,
        "sort_by": "popularity.desc",
        "page": page
    })
    return {
        "items": data.get("results", []),
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
        tasks = [
            tmdb_get(f"/discover/{mtype}", {
                "with_genres": genre["id"],
                "sort_by": "popularity.desc",
                "page": p
            })
            for p in range(1, 3)
        ]
        pages = await asyncio.gather(*tasks)
        items, seen = [], set()
        for page in pages:
            for item in page.get("results", []):
                if item["id"] not in seen:
                    seen.add(item["id"])
                    items.append(item)
        suffix = "" if type != "all" else (" — Films" if mtype == "movie" else " — Series")
        return {
            "key": f"genre_{genre['id']}_{mtype}",
            "title": genre["name"] + suffix,
            "items": items
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
        tasks = [tmdb_get("/search/movie", {"query": q, "page": p}) for p in range(1, 6)]
        pages = await asyncio.gather(*tasks)
        items, seen = [], set()
        for pg in pages:
            for item in pg.get("results", []):
                if item["id"] not in seen:
                    seen.add(item["id"])
                    items.append(item)
        first = pages[0]
        return {
            "items": items,
            "page": 5,
            "total_pages": first.get("total_pages", 1),
            "total_results": first.get("total_results", 0),
        }
    data = await tmdb_get("/search/movie", {"query": q, "page": page})
    return {
        "items": data.get("results", []),
        "page": page,
        "total_pages": data.get("total_pages", 1),
        "total_results": data.get("total_results", 0),
    }

@router.get("/tv")
async def search_tv(q: str = Query(..., min_length=1), page: int = 1):
    import asyncio
    if page == 1:
        tasks = [tmdb_get("/search/tv", {"query": q, "page": p}) for p in range(1, 6)]
        pages = await asyncio.gather(*tasks)
        items, seen = [], set()
        for pg in pages:
            for item in pg.get("results", []):
                if item["id"] not in seen:
                    seen.add(item["id"])
                    items.append(item)
        first = pages[0]
        return {
            "items": items,
            "page": 5,
            "total_pages": first.get("total_pages", 1),
            "total_results": first.get("total_results", 0),
        }
    data = await tmdb_get("/search/tv", {"query": q, "page": page})
    return {
        "items": data.get("results", []),
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
