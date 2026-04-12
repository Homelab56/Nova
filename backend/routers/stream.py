import httpx
import os
import json
import asyncio
import urllib.parse
import hashlib
import time
import shutil
from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse, FileResponse, RedirectResponse
from pydantic import BaseModel
from .config_loader import get_rd_token

router = APIRouter()

RD_BASE = "https://api.real-debrid.com/rest/1.0"

_HLS_ROOT = "/tmp/nova_hls"
_HLS_SESSIONS: dict[str, dict] = {}


def _hls_cleanup():
    now = time.time()
    for sid, s in list(_HLS_SESSIONS.items()):
        if now - s.get("last_access", now) < 60 * 60:
            continue
        proc = s.get("proc")
        if proc and proc.returncode is None:
            try:
                proc.terminate()
            except Exception:
                pass
        dir_path = s.get("dir")
        if dir_path:
            try:
                shutil.rmtree(dir_path, ignore_errors=True)
            except Exception:
                pass
        _HLS_SESSIONS.pop(sid, None)


def rd_headers():
    return {"Authorization": f"Bearer {get_rd_token()}"}


class UnrestrictRequest(BaseModel):
    link: str


@router.post("/unrestrict")
async def unrestrict_link(body: UnrestrictRequest):
    """
    Zet een Real-Debrid 'restricted' link om naar een directe streambare URL.
    Dit is de laatste stap voor je de video kan afspelen.
    """
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"{RD_BASE}/unrestrict/link",
            headers=rd_headers(),
            data={"link": body.link}
        )
        r.raise_for_status()
        data = r.json()

    return {
        "filename": data.get("filename"),
        "filesize": data.get("filesize"),
        "stream_url": data.get("download"),  # Dit is de directe URL voor de player
        "quality": data.get("quality"),
    }


def _safe_media_path(rel_path: str) -> str:
    rel_path = urllib.parse.unquote(rel_path or "")
    rel_path = rel_path.replace("\\", "/").lstrip("/")
    full_path = os.path.normpath(os.path.join("/media", rel_path))
    if not full_path.startswith("/media/") and full_path != "/media":
        raise HTTPException(status_code=400, detail="Ongeldig pad")
    return full_path


def _resolve_media_file(rel_path: str) -> str:
    full_path = _safe_media_path(rel_path)

    if os.path.exists(full_path):
        return full_path

    if os.path.lexists(full_path) and os.path.islink(full_path):
        try:
            target = os.readlink(full_path)
        except Exception:
            target = ""

        if target:
            if not os.path.isabs(target):
                target = os.path.normpath(os.path.join(os.path.dirname(full_path), target))
            else:
                media_host = (os.getenv("MEDIA_PATH") or "").rstrip("/")
                if media_host and target.startswith(media_host + "/"):
                    target = "/media" + target[len(media_host):]

            if target.startswith("/media/") and os.path.exists(target):
                return target

    raise HTTPException(
        status_code=404,
        detail=f"Bestand niet gevonden in container: {full_path}",
    )


def _is_http_url(value: str) -> bool:
    v = (value or "").lower()
    return v.startswith("http://") or v.startswith("https://")


async def _ffprobe_streams(input_value: str, is_path: bool) -> dict:
    args = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "stream=index,codec_type,codec_name",
        "-of",
        "json",
        input_value,
    ]
    if _is_http_url(input_value):
        args.insert(4, "5000000")
        args.insert(4, "-rw_timeout")
    if is_path:
        args[-1] = input_value

    proc = await asyncio.create_subprocess_exec(
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    out, _err = await proc.communicate()
    if proc.returncode != 0:
        return {}
    try:
        return json.loads(out.decode("utf-8"))
    except Exception:
        return {}


def _choose_mode(probe: dict) -> str:
    streams = probe.get("streams") or []
    v = next((s for s in streams if s.get("codec_type") == "video"), None)
    a = next((s for s in streams if s.get("codec_type") == "audio"), None)
    v_codec = (v or {}).get("codec_name") or ""
    a_codec = (a or {}).get("codec_name") or ""

    if v_codec == "h264" and a_codec in {"aac", "mp3"}:
        return "copy"
    if v_codec == "h264" and not a_codec:
        return "copy"
    return "transcode"


async def _ffmpeg_stream(input_value: str, mode: str, is_path: bool):
    base = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-i",
        input_value,
        "-map",
        "0:v:0",
        "-map",
        "0:a:0?",
        "-sn",
        "-movflags",
        "frag_keyframe+empty_moov+faststart",
        "-f",
        "mp4",
        "pipe:1",
    ]
    if _is_http_url(input_value):
        insert_at = base.index("-i")
        base[insert_at:insert_at] = [
            "-rw_timeout",
            "15000000",
            "-reconnect",
            "1",
            "-reconnect_streamed",
            "1",
            "-reconnect_delay_max",
            "2",
        ]

    if mode == "copy":
        cmd = base[:]
        cmd.insert(cmd.index("-sn"), "-c:v")
        cmd.insert(cmd.index("-sn") + 1, "copy")
        cmd.insert(cmd.index("-sn"), "-c:a")
        cmd.insert(cmd.index("-sn") + 1, "copy")
    else:
        cmd = base[:]
        cmd.insert(cmd.index("-sn"), "-c:v")
        cmd.insert(cmd.index("-sn") + 1, "libx264")
        cmd.insert(cmd.index("-sn"), "-preset")
        cmd.insert(cmd.index("-sn") + 1, "veryfast")
        cmd.insert(cmd.index("-sn"), "-crf")
        cmd.insert(cmd.index("-sn") + 1, "23")
        cmd.insert(cmd.index("-sn"), "-c:a")
        cmd.insert(cmd.index("-sn") + 1, "aac")
        cmd.insert(cmd.index("-sn"), "-b:a")
        cmd.insert(cmd.index("-sn") + 1, "192k")

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    try:
        first = await proc.stdout.read(1024 * 64)
        if not first:
            err = await proc.stderr.read(1024 * 64)
            try:
                await asyncio.wait_for(proc.wait(), timeout=1)
            except Exception:
                pass
            raise HTTPException(status_code=502, detail=f"Stream start mislukt: {err.decode('utf-8', errors='ignore')[:400]}")
        yield first
        while True:
            chunk = await proc.stdout.read(1024 * 128)
            if not chunk:
                break
            yield chunk
    finally:
        if proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), timeout=2)
            except Exception:
                proc.kill()


@router.get("/play")
async def play(url: str | None = None, path: str | None = None):
    if not url and not path:
        raise HTTPException(status_code=400, detail="url of path is verplicht")

    is_path = path is not None
    input_value = _resolve_media_file(path) if is_path else urllib.parse.unquote(url)

    probe = await _ffprobe_streams(input_value, is_path=is_path)
    mode = _choose_mode(probe) if probe else "transcode"

    return StreamingResponse(
        _ffmpeg_stream(input_value, mode=mode, is_path=is_path),
        media_type="video/mp4",
    )


async def _ensure_hls_session(session_id: str, input_value: str):
    os.makedirs(_HLS_ROOT, exist_ok=True)
    sess_dir = os.path.join(_HLS_ROOT, session_id)
    os.makedirs(sess_dir, exist_ok=True)
    playlist_path = os.path.join(sess_dir, "index.m3u8")
    segment_pattern = os.path.join(sess_dir, "seg_%05d.m4s")
    init_name = "init.mp4"

    s = _HLS_SESSIONS.get(session_id)
    if s and s.get("proc") and s["proc"].returncode is None:
        s["last_access"] = time.time()
        return

    probe = await _ffprobe_streams(input_value, is_path=not _is_http_url(input_value))

    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-i",
        input_value,
        "-map",
        "0:v:0",
        "-map",
        "0:a:0?",
        "-sn",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "23",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-b:a",
        "192k",
        "-ac",
        "2",
        "-f",
        "hls",
        "-hls_time",
        "4",
        "-hls_list_size",
        "0",
        "-hls_playlist_type",
        "event",
        "-hls_segment_type",
        "fmp4",
        "-hls_fmp4_init_filename",
        init_name,
        "-hls_flags",
        "independent_segments",
        "-hls_segment_filename",
        segment_pattern,
        playlist_path,
    ]
    if _is_http_url(input_value):
        insert_at = cmd.index("-i")
        cmd[insert_at:insert_at] = [
            "-rw_timeout",
            "15000000",
            "-reconnect",
            "1",
            "-reconnect_streamed",
            "1",
            "-reconnect_delay_max",
            "2",
        ]

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.PIPE,
    )

    _HLS_SESSIONS[session_id] = {
        "dir": sess_dir,
        "playlist": playlist_path,
        "proc": proc,
        "last_access": time.time(),
    }


@router.get("/hls")
async def hls(url: str | None = None, path: str | None = None):
    if not url and not path:
        raise HTTPException(status_code=400, detail="url of path is verplicht")

    is_path = path is not None
    input_value = _resolve_media_file(path) if is_path else urllib.parse.unquote(url)
    key = ("path:" + input_value) if is_path else ("url:" + input_value)
    session_id = hashlib.sha1(key.encode("utf-8")).hexdigest()

    _hls_cleanup()
    s = _HLS_SESSIONS.get(session_id) or {}
    s["input"] = input_value
    s["is_path"] = is_path
    s["last_access"] = time.time()
    _HLS_SESSIONS[session_id] = s

    # Belangrijk: frontend proxyt enkel /api/* naar de backend.
    # Dus we moeten redirecten naar een pad dat ook met /api begint.
    return RedirectResponse(url=f"/api/stream/hls/{session_id}/index.m3u8", status_code=302)


@router.get("/hls/{session_id}/index.m3u8")
async def hls_index(session_id: str):
    _hls_cleanup()
    s = _HLS_SESSIONS.get(session_id)
    if not s:
        raise HTTPException(status_code=404, detail="Onbekende stream")

    s["last_access"] = time.time()
    await _ensure_hls_session(session_id, s.get("input"))
    playlist_path = _HLS_SESSIONS[session_id]["playlist"]

    for _ in range(50):
        if os.path.exists(playlist_path) and os.path.getsize(playlist_path) > 0:
            break
        await asyncio.sleep(0.1)

    if not os.path.exists(playlist_path) or os.path.getsize(playlist_path) == 0:
        proc = _HLS_SESSIONS[session_id].get("proc")
        err = b""
        if proc and proc.stderr:
            try:
                err = await proc.stderr.read(4096)
            except Exception:
                err = b""
        input_value = s.get("input") or ""
        msg = err.decode("utf-8", errors="ignore").strip()
        if not msg:
            msg = "Geen stderr output van ffmpeg."
        detail = f"HLS start mislukt voor input: {input_value}\n{msg}"
        print(detail)
        raise HTTPException(status_code=502, detail=detail[:1800])

    return FileResponse(
        playlist_path,
        media_type="application/vnd.apple.mpegurl",
        headers={"Cache-Control": "no-cache"},
    )


@router.get("/hls/{session_id}/{segment_name}")
async def hls_segment(session_id: str, segment_name: str):
    s = _HLS_SESSIONS.get(session_id)
    if not s:
        raise HTTPException(status_code=404, detail="Onbekende stream")

    s["last_access"] = time.time()
    dir_path = _HLS_SESSIONS[session_id].get("dir")
    if not dir_path:
        raise HTTPException(status_code=404, detail="Onbekende stream")
    if ".." in segment_name or "/" in segment_name or "\\" in segment_name:
        raise HTTPException(status_code=400, detail="Ongeldig segment")

    seg_path = os.path.join(dir_path, segment_name)
    if not os.path.exists(seg_path):
        for _ in range(40):
            if os.path.exists(seg_path):
                break
            await asyncio.sleep(0.05)
    if not os.path.exists(seg_path):
        raise HTTPException(status_code=404, detail="Segment niet gevonden")

    lower = segment_name.lower()
    if lower.endswith(".m4s"):
        media_type = "video/iso.segment"
    elif lower.endswith(".ts"):
        media_type = "video/MP2T"
    elif lower.endswith(".mp4"):
        media_type = "video/mp4"
    else:
        media_type = "application/octet-stream"

    return FileResponse(
        seg_path,
        media_type=media_type,
        headers={"Cache-Control": "no-cache"},
    )
