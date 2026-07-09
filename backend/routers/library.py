import os
import re
import asyncio
import time
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel
from typing import List, Optional

router = APIRouter()

MEDIA_ROOT = "/media"

# Cache voor de bibliotheek om heavy disk I/O te voorkomen
# We slaan de volledige lijst van genormaliseerde paden op voor razendsnel zoeken
_LIBRARY_CACHE = {"items": [], "last_scan": 0}
_SCAN_LOCK = asyncio.Lock()
CACHE_TTL = 300 # 5 minuten

def _normalize_text(s: str) -> str:
    if not s: return ""
    s = s.lower()
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()

async def get_library_files():
    """Geeft de lijst met bestanden terug. Scan is nu gedeactiveerd tijdens afspelen voor stabiliteit."""
    return _LIBRARY_CACHE["items"]

@router.get("/find")
async def find_file(q: str):
    """
    Zoekt een specifiek bestand. 
    GEACTIVEERD: We doen geen schijf-scans meer tijdens het afspelen om crashes te voorkomen.
    """
    return {"found": False}

@router.get("/refresh")
async def refresh_library():
    """Handmatige verversing van de bibliotheek cache."""
    global _LIBRARY_CACHE
    async with _SCAN_LOCK:
        print("Handmatige scan gestart...")
        def _scan():
            file_list = []
            try:
                if not os.path.exists(MEDIA_ROOT): return []
                for root, dirs, files in os.walk(MEDIA_ROOT):
                    dirs[:] = [d for d in dirs if not d.startswith('.')]
                    if root[len(MEDIA_ROOT):].count(os.sep) > 3: continue
                    for file in files:
                        if file.lower().endswith(('.mp4', '.mkv', '.avi', '.mov', '.m4v')):
                            full_path = os.path.join(root, file)
                            file_list.append({"path": full_path, "name": file})
            except Exception as e:
                print(f"Scan fout: {e}")
            return file_list
        
        items = await asyncio.to_thread(_scan)
        _LIBRARY_CACHE = {"items": items, "last_scan": time.time()}
        return {"status": "done", "count": len(items)}

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
    """Scant de /media directory (lokale videomount) voor bestanden."""
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
