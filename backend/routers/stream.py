import httpx
import os
import json
import asyncio
import urllib.parse
import hashlib
import time
import shutil
from fastapi import APIRouter, HTTPException, Query
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

async def _ffprobe_audio_streams(input_value: str, is_path: bool) -> list[dict]:
    args = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "a",
        "-show_entries",
        "stream=index,codec_name,channels:stream_tags=language,title",
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
        return []
    try:
        data = json.loads(out.decode("utf-8", errors="ignore") or "{}")
        streams = data.get("streams") or []
        if not isinstance(streams, list):
            return []
        return [s for s in streams if isinstance(s, dict)]
    except Exception:
        return []

async def _ffprobe_subtitle_streams(input_value: str, is_path: bool) -> list[dict]:
    args = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "s",
        "-show_entries",
        "stream=index,codec_name:stream_tags=language,title",
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
        return []
    try:
        data = json.loads(out.decode("utf-8", errors="ignore") or "{}")
        streams = data.get("streams") or []
        if not isinstance(streams, list):
            return []
        return [s for s in streams if isinstance(s, dict)]
    except Exception:
        return []

async def _ffmpeg_subtitle_vtt(input_value: str, is_path: bool, stream_index: int):
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-i",
        input_value,
        "-map",
        f"0:{int(stream_index)}",
        "-c:s",
        "webvtt",
        "-f",
        "webvtt",
        "pipe:1",
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
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    stderr_buf = bytearray()

    async def _drain_stderr():
        if not proc.stderr:
            return
        try:
            while True:
                chunk = await proc.stderr.read(4096)
                if not chunk:
                    break
                stderr_buf.extend(chunk)
                if len(stderr_buf) > 128_000:
                    del stderr_buf[:-128_000]
        except Exception:
            return

    stderr_task = asyncio.create_task(_drain_stderr())
    produced = 0
    try:
        while True:
            chunk = await proc.stdout.read(64 * 1024)
            if not chunk:
                break
            produced += len(chunk)
            yield chunk
    finally:
        try:
            if proc.returncode is None:
                proc.kill()
        except Exception:
            pass
        try:
            await asyncio.wait_for(proc.wait(), timeout=0.5)
        except Exception:
            pass
        try:
            await asyncio.wait_for(stderr_task, timeout=0.5)
        except Exception:
            try:
                stderr_task.cancel()
            except Exception:
                pass

        if produced == 0:
            msg = (bytes(stderr_buf).decode("utf-8", errors="ignore") or "").strip()
            if not msg:
                msg = "Geen stderr output van ffmpeg."
            print(
                "FFMPEG subtitles gaf geen data terug\n"
                f"input={input_value}\n"
                f"stream_index={stream_index}\n"
                f"returncode={proc.returncode}\n"
                f"cmd={' '.join(cmd)}\n"
                f"{msg[:1800]}"
            )


async def _ffprobe_streams(input_value: str, is_path: bool) -> dict:
    args = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "stream=index,codec_type,codec_name,width,height",
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


async def _ffprobe_duration_seconds(input_value: str, is_path: bool) -> float | None:
    args = ["ffprobe", "-v", "error", "-show_format", "-of", "json", input_value]
    if _is_http_url(input_value):
        args.insert(4, "5000000")
        args.insert(4, "-rw_timeout")

    proc = await asyncio.create_subprocess_exec(
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        out, _err = await asyncio.wait_for(proc.communicate(), timeout=15)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
        return None
    if proc.returncode != 0 or not out:
        return None
    try:
        data = json.loads(out.decode("utf-8", errors="ignore") or "{}")
        fmt = data.get("format") or {}
        dur = fmt.get("duration")
        if dur is None:
            return None
        return float(dur)
    except Exception:
        return None


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


async def _ffmpeg_stream(input_value: str, is_path: bool, start: float = 0.0, audio_stream_index: int | None = None):
    probe = await _ffprobe_streams(input_value, is_path=is_path)
    streams = (probe or {}).get("streams") or []
    v = next((s for s in streams if s.get("codec_type") == "video"), None) or {}
    a_default = next((s for s in streams if s.get("codec_type") == "audio"), None) or {}
    a = a_default
    selected_audio_map = "0:a:0?"
    if audio_stream_index is not None:
        chosen = None
        for s in streams:
            if s.get("codec_type") != "audio":
                continue
            try:
                if int(s.get("index")) == int(audio_stream_index):
                    chosen = s
                    break
            except Exception:
                continue
        if chosen:
            a = chosen
            selected_audio_map = f"0:{int(audio_stream_index)}"
    v_codec = (v.get("codec_name") or "").lower()
    a_codec = (a.get("codec_name") or "").lower()

    copy_video = v_codec == "h264"
    copy_audio = a_codec == "aac"
    try:
        v_w = int(v.get("width") or 0)
    except Exception:
        v_w = 0
    try:
        v_h = int(v.get("height") or 0)
    except Exception:
        v_h = 0

    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
    ]

    # ALTIJD -ss voor -i (sneller zoeken)
    if start and start > 0:
        cmd += ["-ss", f"{start:.3f}"]

    cmd += [
        "-i",
        input_value,
        "-map",
        "0:v:0",
        "-map",
        selected_audio_map,
        "-sn",
        "-fflags",
        "+genpts",
        "-avoid_negative_ts",
        "make_zero",
    ]

    if copy_video:
        cmd += ["-c:v", "copy"]
    else:
        cmd += [
            "-c:v",
            "libx264",
            "-tune",
            "zerolatency",
            "-g",
            "48",
            "-keyint_min",
            "48",
            "-sc_threshold",
            "0",
            "-preset",
            "ultrafast",
            "-threads",
            "0",
            "-crf",
            "23",
            "-pix_fmt",
            "yuv420p",
        ]
        if v_w >= 2560 or v_h >= 1440:
            cmd += ["-vf", "scale=-2:1080"]

    if copy_audio:
        cmd += ["-c:a", "copy"]
    else:
        cmd += [
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            "-ac",
            "2",
            "-af",
            "aresample=async=1:first_pts=0",
        ]

    cmd += [
        "-f",
        "mp4",
        "-movflags",
        "frag_keyframe+empty_moov+default_base_moof",
        "pipe:1",
    ]

    if _is_http_url(input_value):
        insert_at = cmd.index("-i")
        cmd[insert_at:insert_at] = [
            "-rw_timeout", "15000000",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "2",
        ]

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    stderr_buf = bytearray()

    async def _drain_stderr():
        if not proc.stderr:
            return
        try:
            while True:
                chunk = await proc.stderr.read(4096)
                if not chunk:
                    break
                stderr_buf.extend(chunk)
                if len(stderr_buf) > 256_000:
                    del stderr_buf[:-256_000]
        except Exception:
            return

    stderr_task = asyncio.create_task(_drain_stderr())
    produced = 0
    try:
        while True:
            chunk = await proc.stdout.read(1024 * 1024)
            if not chunk:
                break
            produced += len(chunk)
            yield chunk
    except asyncio.CancelledError:
        pass
    finally:
        try:
            if proc.returncode is None:
                proc.kill()
        except Exception:
            pass
        try:
            await asyncio.wait_for(proc.wait(), timeout=0.5)
        except Exception:
            pass
        try:
            await asyncio.wait_for(stderr_task, timeout=0.5)
        except Exception:
            try:
                stderr_task.cancel()
            except Exception:
                pass

        if produced == 0:
            msg = (bytes(stderr_buf).decode("utf-8", errors="ignore") or "").strip()
            if not msg:
                msg = "Geen stderr output van ffmpeg."
            print(
                "FFMPEG stream gaf geen data terug\n"
                f"input={input_value}\n"
                f"returncode={proc.returncode}\n"
                f"cmd={' '.join(cmd)}\n"
                f"{msg[:1800]}"
            )
        try:
            if proc.returncode is None:
                proc.kill()
        except OSError:
            pass


@router.get("/meta")
async def meta(url: str | None = None, path: str | None = None):
    if not url and not path:
        raise HTTPException(status_code=400, detail="url of path is verplicht")
    is_path = path is not None
    input_value = _resolve_media_file(path) if is_path else urllib.parse.unquote(url)
    dur = await _ffprobe_duration_seconds(input_value, is_path=is_path)
    return {"duration": dur or 0.0}


@router.get("/play")
async def play(
    url: str | None = None,
    path: str | None = None,
    start: float = Query(default=0.0, ge=0.0),
    a: int | None = Query(default=None),
):
    if not url and not path:
        raise HTTPException(status_code=400, detail="url of path is verplicht")

    is_path = path is not None
    input_value = _resolve_media_file(path) if is_path else urllib.parse.unquote(url)

    return StreamingResponse(
        _ffmpeg_stream(input_value, is_path=is_path, start=start, audio_stream_index=a),
        media_type="video/mp4",
    )


@router.get("/audio")
async def audio(url: str | None = None, path: str | None = None):
    if not url and not path:
        raise HTTPException(status_code=400, detail="url of path is verplicht")
    is_path = path is not None
    input_value = _resolve_media_file(path) if is_path else urllib.parse.unquote(url)
    streams = await _ffprobe_audio_streams(input_value, is_path=is_path)
    tracks = []
    for s in streams:
        idx = s.get("index")
        codec = s.get("codec_name") or ""
        channels = s.get("channels") or 0
        tags = s.get("tags") or {}
        if not isinstance(tags, dict):
            tags = {}
        lang = tags.get("language") or ""
        title = tags.get("title") or ""
        try:
            idx_i = int(idx)
        except Exception:
            continue
        try:
            channels_i = int(channels)
        except Exception:
            channels_i = 0
        tracks.append(
            {
                "stream_index": idx_i,
                "language": str(lang),
                "title": str(title),
                "codec": str(codec),
                "channels": channels_i,
            }
        )
    return {"tracks": tracks}


@router.get("/subtitles")
async def subtitles(url: str | None = None, path: str | None = None):
    if not url and not path:
        raise HTTPException(status_code=400, detail="url of path is verplicht")
    is_path = path is not None
    input_value = _resolve_media_file(path) if is_path else urllib.parse.unquote(url)
    streams = await _ffprobe_subtitle_streams(input_value, is_path=is_path)
    tracks = []
    for s in streams:
        idx = s.get("index")
        codec = s.get("codec_name") or ""
        tags = s.get("tags") or {}
        if not isinstance(tags, dict):
            tags = {}
        lang = tags.get("language") or ""
        title = tags.get("title") or ""
        try:
            idx_i = int(idx)
        except Exception:
            continue
        tracks.append(
            {
                "stream_index": idx_i,
                "language": str(lang),
                "title": str(title),
                "codec": str(codec),
            }
        )
    return {"tracks": tracks}


@router.get("/subtitle.vtt")
async def subtitle_vtt(
    stream_index: int,
    url: str | None = None,
    path: str | None = None,
):
    if not url and not path:
        raise HTTPException(status_code=400, detail="url of path is verplicht")
    is_path = path is not None
    input_value = _resolve_media_file(path) if is_path else urllib.parse.unquote(url)
    return StreamingResponse(
        _ffmpeg_subtitle_vtt(input_value, is_path=is_path, stream_index=stream_index),
        media_type="text/vtt",
        headers={"Cache-Control": "no-cache"},
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
        "mp4",
        "-movflags",
        "frag_keyframe+empty_moov+default_base_moof",
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

    q = []
    if path is not None:
        q.append("path=" + urllib.parse.quote(path))
    if url is not None:
        q.append("url=" + urllib.parse.quote(url))
    query = ("?" + "&".join(q)) if q else ""
    return RedirectResponse(url=f"/api/stream/play{query}", status_code=302)


@router.get("/hls/{session_id}/index.m3u8")
async def hls_index(session_id: str):
    _hls_cleanup()
    s = _HLS_SESSIONS.get(session_id)
    if not s:
        raise HTTPException(status_code=404, detail="Onbekende stream")

    s["last_access"] = time.time()
    await _ensure_hls_session(session_id, s.get("input"))
    playlist_path = _HLS_SESSIONS[session_id]["playlist"]

    for _ in range(300):
        if os.path.exists(playlist_path) and os.path.getsize(playlist_path) > 0:
            break
        await asyncio.sleep(0.1)

    if not os.path.exists(playlist_path) or os.path.getsize(playlist_path) == 0:
        proc = _HLS_SESSIONS[session_id].get("proc")
        err = b""
        rc = None
        if proc:
            rc = proc.returncode
            if rc is None:
                try:
                    rc = await asyncio.wait_for(proc.wait(), timeout=0.1)
                except Exception:
                    rc = proc.returncode
        if proc and proc.stderr:
            try:
                err = await proc.stderr.read(65536)
            except Exception:
                err = b""
        input_value = s.get("input") or ""
        msg = err.decode("utf-8", errors="ignore").strip()
        if not msg:
            msg = "Geen stderr output van ffmpeg."
        detail = f"HLS start mislukt voor input: {input_value}\nreturncode={rc}\n{msg}"
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
