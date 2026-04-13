import os
import re
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel
from typing import List, Optional

router = APIRouter()

MEDIA_ROOT = "/media"

class MediaFile(BaseModel):
    name: str
    path: str
    size: int
    is_video: bool

def is_video_file(filename: str) -> bool:
    return filename.lower().endswith(('.mp4', '.mkv', '.avi', '.mov', '.m4v'))

def _normalize_text(s: str) -> str:
    if not s:
        return ""
    s = s.lower()
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()

@router.get("/all")
async def all_library_files():
    """Scant recursief de /media directory voor alle videobestanden (max 100)."""
    items = []
    try:
        for root, dirs, files in os.walk(MEDIA_ROOT):
            # Skip verborgen mappen
            dirs[:] = [d for d in dirs if not d.startswith('.')]
            
            # Beperk diepte voor performance
            depth = root[len(MEDIA_ROOT):].count(os.sep)
            if depth > 4:
                continue

            for file in files:
                if is_video_file(file):
                    full_path = os.path.join(root, file)
                    items.append({
                        "name": file,
                        "path": os.path.relpath(full_path, MEDIA_ROOT).replace("\\", "/"),
                        "size": os.path.getsize(full_path) if os.path.exists(full_path) else 0,
                        "is_dir": False,
                        "is_video": True
                    })
                    if len(items) >= 100:
                        return sorted(items, key=lambda x: x["name"].lower())
    except Exception as e:
        print(f"Fout bij ophalen alle bestanden: {e}")
    
    return sorted(items, key=lambda x: x["name"].lower())

@router.get("/scan")
async def scan_library(path: str = ""):
    """Scant de /media directory (Dumbarr mount) voor bestanden."""
    full_path = os.path.join(MEDIA_ROOT, path.lstrip("/"))
    if not os.path.exists(full_path):
        return []
    
    items = []
    try:
        for entry in os.scandir(full_path):
            is_video = is_video_file(entry.name)
            items.append({
                "name": entry.name,
                "path": os.path.relpath(entry.path, MEDIA_ROOT),
                "size": entry.stat().st_size if entry.is_file() else 0,
                "is_dir": entry.is_dir(),
                "is_video": is_video
            })
    except Exception as e:
        print(f"Fout bij scannen: {e}")
        return []
    
    return sorted(items, key=lambda x: (not x["is_dir"], x["name"].lower()))

@router.get("/find")
async def find_file(q: str):
    """Zoekt een specifiek bestand op de mount gebaseerd op een query (bijv. 'The Boys S01E01')."""
    q_clean = _normalize_text(q)
    raw = (q or "").lower()
    ep = None
    m = re.search(r"\bs(\d{1,2})e(\d{1,2})\b", raw)
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
    words = [
        w
        for w in words
        if not re.fullmatch(r"s\d{2}e\d{2}", w)
        and not re.fullmatch(r"\d{1,2}x\d{2}", w)
        and not re.fullmatch(r"(19\d{2}|20\d{2})", w)
    ]
    
    if not words:
        return {"found": False}

    best_match = None
    best_score = 0

    # We scannen de hele boom (beperkt tot 3 diep voor performance)
    for root, dirs, files in os.walk(MEDIA_ROOT):
        # Skip verborgen mappen
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        
        depth = root[len(MEDIA_ROOT):].count(os.sep)
        if depth > 4:
            continue

        for file in files:
            if not is_video_file(file):
                continue
            
            candidate_path = os.path.join(root, file)
            if not os.path.exists(candidate_path):
                continue

            file_lower = _normalize_text(file)
            if ep_tokens and not any(t in file_lower for t in ep_tokens):
                continue
            score = sum(1 for word in words if word in file_lower)
            
            # Bonus voor exacte match op SxxExx
            if ep_tokens and any(t in file_lower for t in ep_tokens):
                score += 5

            if score > best_score and score >= len(words):
                best_score = score
                best_match = candidate_path

    if best_match:
        # We geven een URL terug die de browser kan afspelen via de /library/stream endpoint
        rel_path = os.path.relpath(best_match, MEDIA_ROOT).replace("\\", "/")
        import urllib.parse
        encoded_path = urllib.parse.quote(rel_path)
        return {
            "found": True, 
            "path": rel_path, 
            "stream_url": f"/api/library/stream?path={encoded_path}"
        }
    
    return {"found": False}

@router.get("/stream")
async def stream_file(path: str):
    """Serveert een bestand van de mount."""
    full_path = os.path.join(MEDIA_ROOT, path.lstrip("/"))
    if not os.path.exists(full_path) or not os.path.isfile(full_path):
        raise HTTPException(status_code=404, detail="Bestand niet gevonden")
    
    return FileResponse(full_path)
