import os
import re
import asyncio
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel
from typing import List, Optional

router = APIRouter()

MEDIA_ROOT = "/media"

# Cache voor de bibliotheek om heavy disk I/O te voorkomen
_LIBRARY_CACHE = {"items": [], "last_scan": 0}
_SCAN_LOCK = asyncio.Lock()

def _scan_disk():
    """Synchrone disk scan voor gebruik in threadpool."""
    items = []
    try:
        for root, dirs, files in os.walk(MEDIA_ROOT):
            dirs[:] = [d for d in dirs if not d.startswith('.')]
            depth = root[len(MEDIA_ROOT):].count(os.sep)
            if depth > 4:
                continue
            for file in files:
                if file.lower().endswith(('.mp4', '.mkv', '.avi', '.mov', '.m4v')):
                    full_path = os.path.join(root, file)
                    items.append(full_path)
    except Exception as e:
        print(f"Disk scan fout: {e}")
    return items

@router.get("/find")
async def find_file(q: str):
    """Zoekt een specifiek bestand op de mount gebaseerd op een query."""
    q_clean = _normalize_text(q)
    raw = (q or "").lower()
    
    # Gebruik asyncio.to_thread om de event loop niet te blokkeren tijdens disk I/O
    def _do_find():
        year_match = re.findall(r"\b(19\d{2}|20\d{2})\b", raw)
        query_year = int(year_match[-1]) if year_match else None
        
        m = re.search(r"\bs(\d{1,2})e(\d{1,2})\b", raw)
        ep = None
        if m:
            ss, ee = m.groups()
            ep = (int(ss), int(ee))
        else:
            m = re.search(r"\b(\d{1,2})x(\d{1,2})\b", raw)
            if m:
                ss, ee = m.groups()
                ep = (int(ss), int(ee))

        ep_tokens = set()
        if ep:
            ss, ee = ep
            ep_tokens = {f"s{ss:02d}e{ee:02d}", f"{ss}x{ee:02d}", f"{ss:02d}x{ee:02d}"}

        words = [w for w in q_clean.split() if len(w) >= 2]
        words = [w for w in words if not re.fullmatch(r"s\d{2}e\d{2}", w) and not re.fullmatch(r"\d{1,2}x\d{2}", w) and not re.fullmatch(r"(19\d{2}|20\d{2})", w)]
        
        if not words: return None

        best_match = None
        best_score = 0
        min_score = len(words)

        # Beperk de scan diepte en gebruik os.scandir voor snelheid indien mogelijk, 
        # maar voor nu houden we os.walk in een thread.
        for root, dirs, files in os.walk(MEDIA_ROOT):
            dirs[:] = [d for d in dirs if not d.startswith('.')]
            if root[len(MEDIA_ROOT):].count(os.sep) > 4: continue

            for file in files:
                if not file.lower().endswith(('.mp4', '.mkv', '.avi', '.mov', '.m4v')): continue
                
                candidate_path = os.path.join(root, file)
                full_path_lower = _normalize_text(candidate_path)

                if query_year and not ep_tokens:
                    path_years = {int(y) for y in re.findall(r"\b(19\d{2}|20\d{2})\b", candidate_path)}
                    if query_year not in path_years: continue

                score = sum(1 for word in words if word in full_path_lower)
                if score < min_score: continue
                if ep_tokens and not any(t in full_path_lower for t in ep_tokens): continue
                
                if ep_tokens and any(t in _normalize_text(file) for t in ep_tokens):
                    score += 5

                if score > best_score:
                    best_score = score
                    best_match = candidate_path
        return best_match

    best_match = await asyncio.to_thread(_do_find)

    if best_match:
        rel_path = os.path.relpath(best_match, MEDIA_ROOT).replace("\\", "/")
        import urllib.parse
        encoded_path = urllib.parse.quote(rel_path)
        return {"found": True, "path": rel_path, "stream_url": f"/api/library/stream?path={encoded_path}"}
    
    return {"found": False}

@router.get("/all")
async def all_library_files():
    """Scant recursief de /media directory voor alle videobestanden (max 100)."""
    def _do_scan():
        items = []
        try:
            for root, dirs, files in os.walk(MEDIA_ROOT):
                dirs[:] = [d for d in dirs if not d.startswith('.')]
                depth = root[len(MEDIA_ROOT):].count(os.sep)
                if depth > 4: continue
                for file in files:
                    if file.lower().endswith(('.mp4', '.mkv', '.avi', '.mov', '.m4v')):
                        full_path = os.path.join(root, file)
                        items.append({
                            "name": file,
                            "path": os.path.relpath(full_path, MEDIA_ROOT).replace("\\", "/"),
                            "size": os.path.getsize(full_path) if os.path.exists(full_path) else 0,
                            "is_dir": False,
                            "is_video": True
                        })
                        if len(items) >= 100: return items
        except Exception as e:
            print(f"Fout bij ophalen alle bestanden: {e}")
        return items

    items = await asyncio.to_thread(_do_scan)
    return sorted(items, key=lambda x: x["name"].lower())

@router.get("/scan")
async def scan_library(path: str = ""):
    """Scant de /media directory (Dumbarr mount) voor bestanden."""
    def _do_scan():
        full_path = os.path.join(MEDIA_ROOT, path.lstrip("/"))
        if not os.path.exists(full_path): return []
        items = []
        try:
            for entry in os.scandir(full_path):
                is_video = entry.name.lower().endswith(('.mp4', '.mkv', '.avi', '.mov', '.m4v'))
                items.append({
                    "name": entry.name,
                    "path": os.path.relpath(entry.path, MEDIA_ROOT),
                    "size": entry.stat().st_size if entry.is_file() else 0,
                    "is_dir": entry.is_dir(),
                    "is_video": is_video
                })
        except Exception as e:
            print(f"Fout bij scannen: {e}")
        return items

    items = await asyncio.to_thread(_do_scan)
    return sorted(items, key=lambda x: (not x["is_dir"], x["name"].lower()))

@router.get("/stream")
async def stream_file(path: str):
    """Serveert een bestand van de mount."""
    full_path = os.path.join(MEDIA_ROOT, path.lstrip("/"))
    if not os.path.exists(full_path) or not os.path.isfile(full_path):
        raise HTTPException(status_code=404, detail="Bestand niet gevonden")
    
    return FileResponse(full_path)
