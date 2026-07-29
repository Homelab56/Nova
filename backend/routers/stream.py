import httpx
import os
import json
import asyncio
import urllib.parse
import hashlib
import time
import shutil
import mimetypes
import re
import tempfile
from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import StreamingResponse, FileResponse, RedirectResponse, Response
from pydantic import BaseModel
from .config_loader import get_rd_token, get_opensubtitles_key

router = APIRouter()

RD_BASE = "https://api.real-debrid.com/rest/1.0"

_HLS_ROOT = "/tmp/nova_hls"
_HLS_SESSIONS: dict[str, dict] = {}
_LAST_START: dict[str, tuple[float, float]] = {}

_ALLOWED_LANG_PREFIXES = (
    "en", "eng", "english", "engels",
    "nl", "nld", "dut", "vla", "vlaams", "flemish", "nederlands",
)


def _norm_lang(s: str) -> str:
    return (s or "").lower().strip().replace("_", "-")


def _is_allowed_lang(language: str, title: str = "") -> bool:
    l = _norm_lang(language)
    t = _norm_lang(title)
    if not l and not t:
        return True
    for a in _ALLOWED_LANG_PREFIXES:
        if l and (l.startswith(a) or a.startswith(l) and len(l) >= 2):
            return True
        if t and a in t:
            return True
    return False


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
        task = s.get("stderr_task")
        if task:
            try:
                task.cancel()
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


def _parse_range_header(value: str, size: int) -> tuple[int, int] | None:
    if not value or not isinstance(value, str):
        return None
    if not value.startswith("bytes="):
        return None
    spec = value[len("bytes=") :].strip()
    if "," in spec:
        return None
    if "-" not in spec:
        return None
    start_s, end_s = spec.split("-", 1)
    start_s = start_s.strip()
    end_s = end_s.strip()
    if not start_s and not end_s:
        return None

    if start_s:
        try:
            start = int(start_s)
        except Exception:
            return None
        if start < 0:
            return None
        end = size - 1
        if end_s:
            try:
                end = int(end_s)
            except Exception:
                return None
    else:
        try:
            suffix = int(end_s)
        except Exception:
            return None
        if suffix <= 0:
            return None
        start = max(0, size - suffix)
        end = size - 1

    if start >= size:
        return None
    end = min(end, size - 1)
    if end < start:
        return None
    return start, end

async def _ffprobe_subtitle_streams(input_value: str, is_path: bool) -> list[dict]:
    http = _is_http_url(input_value)
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
    ]
    if http:
        args.extend([
            "-rw_timeout", "60000000",
            "-timeout", "90000000",
            "-user_agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            "-headers", "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36\r\nAccept: */*\r\nConnection: keep-alive\r\n",
            "-analyzeduration", "120000000",
            "-probesize", "120000000",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
        ])
    args.append(input_value)
    if is_path:
        args[-1] = input_value

    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        timeout = 60 if http else 20
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        if proc.returncode != 0:
            msg = (err or b"").decode("utf-8", errors="ignore").strip() or "geen stderr"
            print(f"ffprobe subtitle streams failed for {input_value[:120]}: returncode {proc.returncode}: {msg[:400]}")
            return []
        data = json.loads(out.decode("utf-8", errors="ignore") or "{}")
        streams = data.get("streams") or []
        return [s for s in streams if isinstance(s, dict)]
    except Exception as e:
        print(f"FFProbe subtitle fout voor {input_value[:120]}: {e}")
        return []


async def _ffprobe_audio_streams(input_value: str, is_path: bool) -> list[dict]:
    http = _is_http_url(input_value)
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
    ]
    if http:
        args.extend([
            "-rw_timeout", "60000000",
            "-timeout", "90000000",
            "-user_agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            "-headers", "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36\r\nAccept: */*\r\nConnection: keep-alive\r\n",
            "-analyzeduration", "120000000",
            "-probesize", "120000000",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
        ])
    args.append(input_value)
    if is_path:
        args[-1] = input_value

    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        timeout = 60 if http else 20
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        if proc.returncode != 0:
            msg = (err or b"").decode("utf-8", errors="ignore").strip() or "geen stderr"
            print(f"ffprobe audio streams failed for {input_value[:120]}: returncode {proc.returncode}: {msg[:400]}")
            return []
        data = json.loads(out.decode("utf-8", errors="ignore") or "{}")
        streams = data.get("streams") or []
        return [s for s in streams if isinstance(s, dict)]
    except Exception as e:
        print(f"FFProbe audio fout voor {input_value[:120]}: {e}")
        return []


def _parse_vtt_timestamp(value: str) -> float | None:
    v = (value or "").strip()
    if not v:
        return None
    v = v.replace(",", ".")
    parts = v.split(":")
    if len(parts) == 3:
        h_s, m_s, s_ms = parts
    elif len(parts) == 2:
        h_s, m_s, s_ms = "0", parts[0], parts[1]
    else:
        return None
    if "." not in s_ms:
        return None
    s_s, ms_s = s_ms.split(".", 1)
    try:
        h = int(h_s)
        m = int(m_s)
        s = int(s_s)
        ms_digits = "".join(ch for ch in ms_s if ch.isdigit())
        ms = int((ms_digits + "000")[:3]) if ms_digits else 0
    except Exception:
        return None
    if h < 0 or m < 0 or s < 0 or ms < 0:
        return None
    return (h * 3600) + (m * 60) + s + (ms / 1000.0)


def _format_vtt_timestamp(seconds: float) -> str:
    total_ms = int(round(max(0.0, float(seconds or 0.0)) * 1000.0))
    ms = total_ms % 1000
    total_s = total_ms // 1000
    s = total_s % 60
    total_m = total_s // 60
    m = total_m % 60
    h = total_m // 60
    return f"{h:02}:{m:02}:{s:02}.{ms:03}"


def _shift_webvtt(text: str, shift_seconds: float) -> str:
    try:
        shift = float(shift_seconds or 0.0)
    except Exception:
        shift = 0.0
    if not (shift and abs(shift) > 0.0005):
        return (text or "")
    normalized = (text or "").replace("\r\n", "\n").replace("\r", "\n")
    lines = normalized.split("\n")
    blocks: list[list[str]] = []
    cur: list[str] = []
    for line in lines:
        if line.strip() == "":
            blocks.append(cur)
            cur = []
        else:
            cur.append(line)
    if cur:
        blocks.append(cur)

    out_blocks: list[list[str]] = []
    timing_re = re.compile(r"^\s*(\S+)\s*-->\s*(\S+)(.*)$")
    for b in blocks:
        if not b:
            continue
        timing_idx = next((i for i, ln in enumerate(b) if "-->" in ln), None)
        if timing_idx is None:
            out_blocks.append(b)
            continue
        m = timing_re.match(b[timing_idx])
        if not m:
            out_blocks.append(b)
            continue
        start_ts, end_ts, rest = m.group(1), m.group(2), m.group(3) or ""
        start_s = _parse_vtt_timestamp(start_ts)
        end_s = _parse_vtt_timestamp(end_ts)
        if start_s is None or end_s is None:
            out_blocks.append(b)
            continue
        new_start = start_s + shift
        new_end = end_s + shift
        if new_end <= 0.001:
            continue
        if new_start < 0:
            new_start = 0.0
        if new_end <= new_start + 0.001:
            continue
        b2 = list(b)
        b2[timing_idx] = f"{_format_vtt_timestamp(new_start)} --> {_format_vtt_timestamp(new_end)}{rest}"
        out_blocks.append(b2)

    if not out_blocks:
        return "WEBVTT\n"
    return "\n\n".join("\n".join(b) for b in out_blocks).strip("\n") + "\n"


async def _ffmpeg_subtitle_vtt(
    input_value: str,
    is_path: bool,
    stream_index: int,
    start: float = 0.0,
    delay: float = 0.0,
):
    http = _is_http_url(input_value)
    try:
        start_f = float(start or 0.0)
    except Exception:
        start_f = 0.0
    start_f = max(0.0, start_f)
    try:
        delay_f = float(delay or 0.0)
    except Exception:
        delay_f = 0.0

    http_common = [
        "-rw_timeout",
        "60000000",
        "-timeout",
        "90000000",
        "-user_agent",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
        "-headers",
        "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36\r\nAccept: */*\r\nConnection: keep-alive\r\n",
        "-reconnect",
        "1",
        "-reconnect_streamed",
        "1",
        "-reconnect_delay_max",
        "5",
    ]

    if not (start_f and start_f > 0):
        cmd = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
        ]
        if http:
            cmd.extend(http_common)
        cmd.extend([
            "-i",
            input_value,
            "-map",
            f"0:{int(stream_index)}",
            "-c:s",
            "webvtt",
            "-f",
            "webvtt",
            "pipe:1",
        ])

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
        return

    cmd_seek = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
    ]
    if http:
        cmd_seek.extend(http_common)
    cmd_seek.extend([
        "-ss",
        f"{start_f:.3f}",
        "-i",
        input_value,
        "-map",
        f"0:{int(stream_index)}",
        "-c:s",
        "webvtt",
        "-copyts",
        "-start_at_zero",
        "-avoid_negative_ts",
        "make_zero",
        "-f",
        "webvtt",
        "pipe:1",
    ])

    proc = await asyncio.create_subprocess_exec(
        *cmd_seek,
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
    buf = ""
    try:
        while True:
            chunk = await proc.stdout.read(64 * 1024)
            if not chunk:
                break
            produced += len(chunk)
            if delay_f and abs(delay_f) > 0.0005:
                try:
                    buf += chunk.decode("utf-8", errors="ignore")
                except Exception:
                    yield chunk
                    continue
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    if "-->" in line:
                        try:
                            m = re.match(r"^\s*(\S+)\s*-->\s*(\S+)(.*)$", line)
                            if m:
                                s1, s2, rest = m.group(1), m.group(2), m.group(3) or ""
                                t1 = _parse_vtt_timestamp(s1)
                                t2 = _parse_vtt_timestamp(s2)
                                if t1 is not None and t2 is not None:
                                    t1n = max(0.0, t1 + delay_f)
                                    t2n = max(0.0, t2 + delay_f)
                                    line = f"{_format_vtt_timestamp(t1n)} --> {_format_vtt_timestamp(t2n)}{rest}"
                        except Exception:
                            pass
                    yield (line + "\n").encode("utf-8")
            else:
                yield chunk
    finally:
        if delay_f and abs(delay_f) > 0.0005 and buf:
            yield buf.encode("utf-8")
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
                f"cmd={' '.join(cmd_seek)}\n"
                f"{msg[:1800]}"
            )


async def _ffprobe_streams(input_value: str, is_path: bool) -> dict:
    args = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "stream=index,codec_type,codec_name,width,height,channels",
        "-of",
        "json",
        input_value,
    ]
    if _is_http_url(input_value):
        args.insert(4, "5000000")
        args.insert(4, "-rw_timeout")
    if is_path:
        args[-1] = input_value

    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out, _err = await asyncio.wait_for(proc.communicate(), timeout=8)
        if proc.returncode != 0: return {}
        return json.loads(out.decode("utf-8"))
    except Exception as e:
        print(f"FFProbe streams fout: {e}")
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


async def _ffmpeg_stream(input_value: str, is_path: bool, start: float = 0.0, audio_stream: int | None = None):
    probe = await _ffprobe_streams(input_value, is_path=is_path)
    streams = (probe or {}).get("streams") or []
    v = next((s for s in streams if s.get("codec_type") == "video"), None) or {}
    a = next((s for s in streams if s.get("codec_type") == "audio"), None) or {}
    v_codec = (v.get("codec_name") or "").lower()
    a_codec = (a.get("codec_name") or "").lower()
    try:
        v_height = int(v.get("height") or 0)
    except Exception:
        v_height = 0
    try:
        a_channels = int(a.get("channels") or 0)
    except Exception:
        a_channels = 0

    copy_video = v_codec == "h264"
    copy_audio = a_codec in {"aac", "mp3"}
    try:
        start_f = float(start or 0.0)
    except Exception:
        start_f = 0.0
    start_f = max(0.0, start_f)
    if start_f > 0:
        copy_video = False
        copy_audio = False
    try:
        max_h = int(os.getenv("TRANSCODE_MAX_HEIGHT", "1080") or "0")
    except Exception:
        max_h = 1080
    try:
        target_fps = float(os.getenv("TRANSCODE_FPS", "0") or "0")
    except Exception:
        target_fps = 0.0
    if not (target_fps and target_fps > 0):
        target_fps = 0.0

    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
    ]

    seek_pre = 0.0
    seek_post = 0.0
    if start_f > 0:
        seek_back = min(10.0, start_f)
        seek_pre = max(0.0, start_f - seek_back)
        seek_post = seek_back
        if seek_pre > 0:
            cmd += ["-ss", f"{seek_pre:.3f}"]

    cmd += [
        "-analyzeduration",
        "10000000",
        "-probesize",
        "10000000",
        "-i",
        input_value,
        "-max_interleave_delta",
        "0",
        "-ss",
        f"{seek_post:.3f}",
        "-map",
        "0:v:0",
    ]
    if audio_stream is not None:
        cmd += ["-map", f"0:{int(audio_stream)}"]
    else:
        cmd += ["-map", "0:a:0?"]
    cmd += [
        "-sn",
        "-fflags",
        "+genpts",
        "-avoid_negative_ts",
        "make_zero",
    ]

    if copy_video:
        cmd += ["-c:v", "copy"]
    else:
        do_scale = bool(max_h and max_h > 0 and v_height and v_height > max_h)
        do_fps = bool(target_fps and target_fps > 0)
        crf = "21" if do_scale else ("18" if v_height >= 1440 else "20")
        vf_parts = []
        if do_fps:
            vf_parts.append(f"fps={target_fps:g}")
        if do_scale:
            vf_parts.append(f"scale=-2:{max_h}:flags=fast_bilinear")
        vf = ",".join(vf_parts) if vf_parts else "null"
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
            "-vf",
            vf,
            "-vsync",
            "1",
            "-crf",
            crf,
            "-pix_fmt",
            "yuv420p",
        ]

    if copy_audio:
        cmd += ["-c:a", "copy"]
    else:
        target_channels = 6 if a_channels >= 6 else 2
        target_bitrate = "384k" if target_channels == 6 else "192k"
        cmd += [
            "-c:a",
            "aac",
            "-b:a",
            target_bitrate,
            "-ac",
            str(target_channels),
            "-af",
            "aresample=async=1:first_pts=0",
        ]

    cmd += [
        "-max_muxing_queue_size",
        "1024",
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
    
    # Get subtitle tracks
    subtitle_streams = await _ffprobe_subtitle_streams(input_value, is_path=is_path)
    bitmap_codecs = {
        "hdmv_pgs_subtitle",
        "dvd_subtitle",
        "dvb_subtitle",
        "xsub",
    }
    subtitle_tracks = []
    for s in subtitle_streams:
        idx = s.get("index")
        codec = s.get("codec_name") or ""
        codec_l = str(codec).lower().strip()
        if codec_l in bitmap_codecs:
            continue
        tags = s.get("tags") or {}
        if not isinstance(tags, dict):
            tags = {}
        lang = tags.get("language") or ""
        title = tags.get("title") or ""
        try:
            idx_i = int(idx)
        except Exception:
            continue
        subtitle_tracks.append(
            {
                "stream_index": idx_i,
                "language": str(lang),
                "title": str(title),
                "codec": str(codec),
            }
        )
    
    # Get audio tracks
    audio_streams = await _ffprobe_audio_streams(input_value, is_path=is_path)
    audio_tracks = []
    for s in audio_streams:
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
        audio_tracks.append(
            {
                "stream_index": idx_i,
                "language": str(lang),
                "title": str(title),
                "codec": str(codec),
                "channels": int(channels),
            }
        )
    
    return {
        "duration": dur or 0.0,
        "subtitle_tracks": subtitle_tracks,
        "audio_tracks": audio_tracks,
    }


# Limiet op het aantal gelijktijdige transcoderingen om de server te beschermen
TRANSCODE_SEMAPHORE = asyncio.Semaphore(3)

@router.get("/play")
async def play(
    request: Request,
    url: str | None = None,
    path: str | None = None,
    start: float = Query(default=0.0, ge=0.0),
    audio_stream: int | None = Query(default=None),
):
    if not url and not path:
        raise HTTPException(status_code=400, detail="url of path is verplicht")

    is_path = path is not None
    input_value = _resolve_media_file(path) if is_path else urllib.parse.unquote(url)

    # Altijd via ffmpeg (ook voor externe AIOStreams URLs): garandeert browser-afspeelbare
    # H.264/AAC output. Bronnen met HEVC/EAC3 (bv. 4K/8K releases) kan een browser niet
    # native decoderen; een kale proxy/redirect van zulke bronnen laat de video eeuwig laden.
    # Compatibele bronnen (h264/aac) worden alsnog via "-c copy" doorgestreamd, dus geen
    # onnodige CPU-kost voor streams die al afspeelbaar zijn.
    async def _stream_with_semaphore():
        async with TRANSCODE_SEMAPHORE:
            async for chunk in _ffmpeg_stream(input_value, is_path=is_path, start=start, audio_stream=audio_stream):
                yield chunk

    try:
        client_host = (request.client.host if request.client else "") or ""
    except Exception:
        client_host = ""
    if client_host and (start and start > 0):
        key = f"{client_host}|{'path' if is_path else 'url'}|{path or url or ''}"
        _LAST_START[key] = (time.time(), float(start))

    return StreamingResponse(
        _stream_with_semaphore(),
        media_type="video/mp4",
        headers={
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        },
    )


async def _proxy_external_url(url: str, request: Request, start: float = 0.0):
    """Proxy externe HTTP URL met range request support voor seeken"""
    # Haal start parameter uit URL query string (voeg toe door frontend)
    parsed = urllib.parse.urlparse(url)
    query_params = urllib.parse.parse_qs(parsed.query)
    url_start = query_params.get("start", [None])[0]
    
    # Verwijder start parameter uit URL
    query_params.pop("start", None)
    new_query = urllib.parse.urlencode(query_params, doseq=True)
    clean_url = urllib.parse.urlunparse((parsed.scheme, parsed.netloc, parsed.path, parsed.params, new_query, parsed.fragment))
    
    range_header = request.headers.get("range") or request.headers.get("Range") or ""
    
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
    }
    if range_header:
        headers["Range"] = range_header
    
    # Gebruik een nog grotere timeout voor streaming
    timeout = httpx.Timeout(600.0, connect=120.0)
    
    max_retries = 3
    for attempt in range(max_retries):
        try:
            async with httpx.AsyncClient(timeout=timeout, follow_redirects=True, verify=False) as client:
                async with client.stream("GET", clean_url, headers=headers) as response:
                    if response.status_code not in [200, 206]:
                        print(f"Externe URL fout: {response.status_code} (poging {attempt + 1}/{max_retries})")
                        if attempt < max_retries - 1:
                            await asyncio.sleep(2 ** attempt)  # Exponential backoff
                            continue
                        raise HTTPException(status_code=response.status_code, detail=f"Externe URL fout: {response.status_code}")
                    
                    content_type = response.headers.get("content-type", "video/mp4")
                    content_length = response.headers.get("content-length")
                    accept_ranges = response.headers.get("accept-ranges", "")
                    
                    response_headers = {
                        "Content-Type": content_type,
                        "Cache-Control": "no-cache",
                        "Access-Control-Allow-Origin": "*",
                        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
                        "Access-Control-Allow-Headers": "Range, Content-Type",
                        "Access-Control-Expose-Headers": "Content-Length, Content-Range, Accept-Ranges",
                    }
                    
                    if content_length:
                        response_headers["Content-Length"] = content_length
                    
                    # Altijd Accept-Ranges: bytes doorgeven als de server dat ondersteunt
                    if accept_ranges == "bytes":
                        response_headers["Accept-Ranges"] = "bytes"
                    
                    if response.status_code == 206:
                        content_range = response.headers.get("content-range")
                        if content_range:
                            response_headers["Content-Range"] = content_range
                    
                    async def iter_chunks():
                        try:
                            async for chunk in response.aiter_bytes(chunk_size=256 * 1024):
                                yield chunk
                        except Exception as e:
                            print(f"Stream error: {e}")
                            raise
                    
                    return StreamingResponse(
                        iter_chunks(),
                        status_code=response.status_code,
                        media_type=content_type,
                        headers=response_headers
                    )
        except httpx.ConnectError as e:
            print(f"Connect error naar {clean_url}: {e} (poging {attempt + 1}/{max_retries})")
            if attempt < max_retries - 1:
                await asyncio.sleep(2 ** attempt)
                continue
            raise HTTPException(status_code=502, detail="Kan geen verbinding maken met stream server")
        except httpx.TimeoutException as e:
            print(f"Timeout naar {clean_url}: {e} (poging {attempt + 1}/{max_retries})")
            if attempt < max_retries - 1:
                await asyncio.sleep(2 ** attempt)
                continue
            raise HTTPException(status_code=504, detail="Stream server timeout")
        except Exception as e:
            print(f"Proxy fout: {e} (poging {attempt + 1}/{max_retries})")
            if attempt < max_retries - 1:
                await asyncio.sleep(2 ** attempt)
                continue
            raise HTTPException(status_code=500, detail=f"Proxy fout: {str(e)}")


@router.get("/file")
async def direct_file(request: Request, path: str):
    input_value = _resolve_media_file(path)
    try:
        stat = os.stat(input_value)
        size = int(stat.st_size)
    except Exception:
        raise HTTPException(status_code=404, detail="Bestand niet gevonden")

    content_type = mimetypes.guess_type(input_value)[0] or "application/octet-stream"
    range_header = request.headers.get("range") or request.headers.get("Range") or ""
    byte_range = _parse_range_header(range_header, size)
    if not byte_range:
        return FileResponse(
            input_value,
            media_type=content_type,
            headers={"Accept-Ranges": "bytes"},
        )

    start, end = byte_range
    length = end - start + 1

    async def _iter_file():
        with open(input_value, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
                yield chunk

    headers = {
        "Content-Range": f"bytes {start}-{end}/{size}",
        "Accept-Ranges": "bytes",
        "Content-Length": str(length),
        "Cache-Control": "no-cache",
    }
    return StreamingResponse(_iter_file(), status_code=206, media_type=content_type, headers=headers)


@router.get("/subtitles")
async def subtitles(url: str | None = None, path: str | None = None):
    if not url and not path:
        raise HTTPException(status_code=400, detail="url of path is verplicht")
    is_path = path is not None
    if is_path:
        input_value = _resolve_media_file(path)
    else:
        input_value = urllib.parse.unquote(url)
    streams = await _ffprobe_subtitle_streams(input_value, is_path=is_path)
    bitmap_codecs = {
        "hdmv_pgs_subtitle",
        "dvd_subtitle",
        "dvb_subtitle",
        "xsub",
    }
    tracks = []
    for s in streams:
        idx = s.get("index")
        codec = s.get("codec_name") or ""
        codec_l = str(codec).lower().strip()
        if codec_l in bitmap_codecs:
            continue
        tags = s.get("tags") or {}
        if not isinstance(tags, dict):
            tags = {}
        lang = tags.get("language") or ""
        title = tags.get("title") or ""
        try:
            idx_i = int(idx)
        except Exception:
            continue
        if not _is_allowed_lang(str(lang), str(title)):
            continue
        tracks.append(
            {
                "stream_index": idx_i,
                "language": str(lang),
                "title": str(title),
                "codec": str(codec),
            }
        )
    print(f"[subtitles] {input_value[:80]} -> {len(tracks)} tracks (na filter)")
    return {"tracks": tracks}


@router.get("/audio")
async def audio(url: str | None = None, path: str | None = None):
    if not url and not path:
        raise HTTPException(status_code=400, detail="url of path is verplicht")
    is_path = path is not None
    if is_path:
        input_value = _resolve_media_file(path)
    else:
        input_value = urllib.parse.unquote(url)
    streams = await _ffprobe_audio_streams(input_value, is_path=is_path)
    tracks = []
    for s in streams:
        idx = s.get("index")
        codec = s.get("codec_name") or ""
        channels = s.get("channels") or ""
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
        if not _is_allowed_lang(str(lang), str(title)):
            continue
        tracks.append(
            {
                "stream_index": idx_i,
                "language": str(lang),
                "title": str(title),
                "codec": str(codec),
                "channels": channels_i,
            }
        )
    print(f"[audio] {input_value[:80]} -> {len(tracks)} tracks (na filter)")
    return {"tracks": tracks}


@router.get("/subtitle.vtt")
async def subtitle_vtt(
    request: Request,
    stream_index: int,
    url: str | None = None,
    path: str | None = None,
    start: float = 0.0,
    delay: float = 0.0,
):
    if not url and not path:
        raise HTTPException(status_code=400, detail="url of path is verplicht")
    is_path = path is not None
    if is_path:
        input_value = _resolve_media_file(path)
    else:
        input_value = urllib.parse.unquote(url)
    streams = await _ffprobe_subtitle_streams(input_value, is_path=is_path)
    for s in streams:
        try:
            if int(s.get("index")) != int(stream_index):
                continue
        except Exception:
            continue
        codec = str(s.get("codec_name") or "").lower().strip()
        if codec in {"hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"}:
            raise HTTPException(status_code=415, detail="Bitmap ondertitels (PGS/DVD) worden niet ondersteund.")
        break
    try:
        start_f = float(start or 0.0)
    except Exception:
        start_f = 0.0
    if not (start_f and start_f > 0):
        ref = request.headers.get("referer") or request.headers.get("referrer") or ""
        try:
            parsed = urllib.parse.urlparse(ref)
            q = urllib.parse.parse_qs(parsed.query or "")
            v = (q.get("start") or [None])[0]
            start_f = float(v or 0.0)
        except Exception:
            start_f = 0.0
    if not (start_f and start_f > 0):
        try:
            client_host = (request.client.host if request.client else "") or ""
        except Exception:
            client_host = ""
        if client_host:
            key = f"{client_host}|{'path' if path is not None else 'url'}|{path or url or ''}"
            entry = _LAST_START.get(key)
            if entry:
                ts, val = entry
                if (time.time() - float(ts)) <= 45:
                    start_f = float(val)

    return StreamingResponse(
        _ffmpeg_subtitle_vtt(input_value, is_path=is_path, stream_index=stream_index, start=start_f, delay=delay),
        media_type="text/vtt",
        headers={"Cache-Control": "no-cache"},
    )


# --- Externe ondertitels (OpenSubtitles) met automatische audio-sync ---

_OS_BASE = "https://api.opensubtitles.com/api/v1"
_OS_USER_AGENT = "Nova v1.0"

# Persistente cache op schijf (i.p.v. in-memory) zodat een eenmaal gezochte en
# gesynchroniseerde ondertitel bij een herbekijking - ook na een herstart of
# nieuwe deploy van de backend - meteen klaarstaat i.p.v. opnieuw te moeten
# zoeken/downloaden/synchroniseren.
_SUB_CACHE_DIR = "/app/data/subtitles_cache"


def _subtitle_cache_path(cache_key: str) -> str:
    os.makedirs(_SUB_CACHE_DIR, exist_ok=True)
    safe_name = hashlib.sha256(cache_key.encode("utf-8")).hexdigest()
    return os.path.join(_SUB_CACHE_DIR, f"{safe_name}.vtt")


def _subtitle_cache_get(cache_key: str) -> str | None:
    path = _subtitle_cache_path(cache_key)
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception as e:
        print(f"Ondertitel-cache lezen mislukt: {e}")
        return None


def _subtitle_cache_set(cache_key: str, vtt: str) -> None:
    path = _subtitle_cache_path(cache_key)
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(vtt)
    except Exception as e:
        print(f"Ondertitel-cache schrijven mislukt: {e}")


def _os_headers() -> dict:
    return {
        "Api-Key": get_opensubtitles_key(),
        "User-Agent": _OS_USER_AGENT,
        "Content-Type": "application/json",
    }


async def _search_opensubtitles(
    tmdb_id: int, media_type: str, language: str, season: int | None, episode: int | None
) -> dict | None:
    if not get_opensubtitles_key():
        return None
    params: dict = {"tmdb_id": tmdb_id, "languages": language}
    if media_type == "tv" and season and episode:
        params["season_number"] = season
        params["episode_number"] = episode
    try:
        async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
            r = await client.get(f"{_OS_BASE}/subtitles", params=params, headers=_os_headers())
        if r.status_code != 200:
            print(f"OpenSubtitles zoekfout: {r.status_code} {r.text[:300]}")
            return None
        items = (r.json().get("data")) or []
        if not items:
            return None
        # Beste match: meeste downloads (proxy voor betrouwbaarheid/kwaliteit).
        items.sort(key=lambda x: ((x.get("attributes") or {}).get("download_count") or 0), reverse=True)
        for item in items:
            files = (item.get("attributes") or {}).get("files") or []
            if files and files[0].get("file_id"):
                return {"file_id": files[0]["file_id"]}
        return None
    except Exception as e:
        print(f"OpenSubtitles zoekfout: {e}")
        return None


async def _download_opensubtitles(file_id: int) -> str | None:
    try:
        async with httpx.AsyncClient(timeout=20, follow_redirects=True) as client:
            r = await client.post(f"{_OS_BASE}/download", json={"file_id": file_id}, headers=_os_headers())
        if r.status_code != 200:
            print(f"OpenSubtitles downloadfout: {r.status_code} {r.text[:300]}")
            return None
        link = r.json().get("link")
        if not link:
            return None
        async with httpx.AsyncClient(timeout=30, follow_redirects=True) as client:
            fr = await client.get(link)
        if fr.status_code != 200:
            return None
        fr.encoding = fr.encoding or "utf-8"
        return fr.text
    except Exception as e:
        print(f"OpenSubtitles downloadfout: {e}")
        return None


async def _extract_reference_audio(video_url: str, out_path: str, duration_secs: int = 300, timeout: float = 150.0) -> bool:
    """
    ffsubsync valideert zijn referentiebestand met os.access(), wat nooit
    lukt voor een URL - dus eerst audio naar een lokaal bestand extraheren.
    Mono/16kHz WAV, beperkt tot de eerste [duration_secs] (genoeg spraak om
    een betrouwbare sync te berekenen, zonder de hele - vaak 10+ GB - bron
    te moeten downloaden).
    """
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
        "-rw_timeout", "20000000",
        "-i", video_url,
        "-t", str(duration_secs),
        "-vn", "-sn",
        "-ac", "1", "-ar", "16000",
        "-acodec", "pcm_s16le",
        "-y", out_path,
    ]
    proc = None
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        _out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        if proc.returncode != 0 or not os.path.exists(out_path) or os.path.getsize(out_path) == 0:
            print(f"Audio-extractie voor ffsubsync mislukt: {(err or b'').decode('utf-8', errors='ignore')[:400]}")
            return False
        return True
    except asyncio.TimeoutError:
        if proc:
            try:
                proc.kill()
            except Exception:
                pass
        print("Audio-extractie voor ffsubsync: timeout")
        return False
    except Exception as e:
        print(f"Audio-extractie voor ffsubsync fout: {e}")
        return False


async def _run_ffsubsync(video_url: str, srt_text: str, timeout: float = 60.0) -> str | None:
    """Lijnt een ondertitel automatisch uit op de audio van de echte stream
    (spraakdetectie), ongeacht welke exacte release we binnenkregen."""
    with tempfile.TemporaryDirectory() as tmp:
        ref_path = os.path.join(tmp, "reference.wav")
        in_path = os.path.join(tmp, "in.srt")
        out_path = os.path.join(tmp, "out.srt")
        with open(in_path, "w", encoding="utf-8") as f:
            f.write(srt_text)

        if not await _extract_reference_audio(video_url, ref_path):
            return None

        cmd = ["ffsubsync", ref_path, "-i", in_path, "-o", out_path]
        proc = None
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            _out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
            if proc.returncode != 0 or not os.path.exists(out_path):
                print(f"ffsubsync fout: {(err or b'').decode('utf-8', errors='ignore')[:600]}")
                return None
            with open(out_path, "r", encoding="utf-8", errors="ignore") as f:
                return f.read()
        except asyncio.TimeoutError:
            if proc:
                try:
                    proc.kill()
                except Exception:
                    pass
            print("ffsubsync: timeout")
            return None
        except Exception as e:
            print(f"ffsubsync fout: {e}")
            return None


def _srt_to_vtt(srt_text: str) -> str:
    body = re.sub(r"(\d{2}:\d{2}:\d{2}),(\d{3})", r"\1.\2", srt_text)
    return "WEBVTT\n\n" + body.strip() + "\n"


@router.get("/subtitle-external.vtt")
async def subtitle_external_vtt(
    url: str,
    tmdb_id: int,
    media_type: str,
    season: int | None = None,
    episode: int | None = None,
    lang: str = "nl",
):
    """
    Zoekt een ondertitel op OpenSubtitles (los van wat er in het videobestand
    zelf zit), en lijnt 'm automatisch uit op de audio van de echte stream via
    ffsubsync - zodat sync niet afhangt van of we toevallig dezelfde release
    als de ondertitel-uploader hadden.
    """
    if not get_opensubtitles_key():
        raise HTTPException(status_code=503, detail="OpenSubtitles is niet geconfigureerd op de server.")

    cache_key = f"{tmdb_id}:{media_type}:{season}:{episode}:{lang}"
    cached = _subtitle_cache_get(cache_key)
    if cached:
        return Response(content=cached, media_type="text/vtt", headers={"Cache-Control": "no-cache"})

    found = await _search_opensubtitles(tmdb_id, media_type, lang, season, episode)
    if not found:
        raise HTTPException(status_code=404, detail=f"Geen {lang}-ondertitels gevonden op OpenSubtitles.")

    srt_text = await _download_opensubtitles(found["file_id"])
    if not srt_text:
        raise HTTPException(status_code=502, detail="Kon ondertitel niet downloaden van OpenSubtitles.")

    input_value = urllib.parse.unquote(url)
    synced_srt = await _run_ffsubsync(input_value, srt_text)
    final_srt = synced_srt or srt_text  # val terug op ongesynchroniseerde versie als sync mislukt
    vtt = _srt_to_vtt(final_srt)
    _subtitle_cache_set(cache_key, vtt)
    return Response(content=vtt, media_type="text/vtt", headers={"Cache-Control": "no-cache"})


async def _ensure_hls_session(session_id: str, input_value: str):
    os.makedirs(_HLS_ROOT, exist_ok=True)
    sess_dir = os.path.join(_HLS_ROOT, session_id)
    os.makedirs(sess_dir, exist_ok=True)
    playlist_path = os.path.join(sess_dir, "index.m3u8")

    s = _HLS_SESSIONS.get(session_id)
    if s and s.get("proc") and s["proc"].returncode is None:
        s["last_access"] = time.time()
        return

    if os.path.exists(playlist_path):
        try:
            os.remove(playlist_path)
        except Exception:
            pass

    for name in os.listdir(sess_dir):
        if name.endswith(".ts") or name.endswith(".m4s") or name.endswith(".mp4") or name.endswith(".tmp"):
            try:
                os.remove(os.path.join(sess_dir, name))
            except Exception:
                pass

    start = float(s.get("start") or 0.0)
    is_path = bool(s.get("is_path"))
    audio_stream = s.get("audio_stream")

    probe = await _ffprobe_streams(input_value, is_path=is_path)
    streams = (probe or {}).get("streams") or []
    v = next((st for st in streams if st.get("codec_type") == "video"), None) or {}
    a = next((st for st in streams if st.get("codec_type") == "audio"), None) or {}
    v_codec = (v.get("codec_name") or "").lower()
    a_codec = (a.get("codec_name") or "").lower()
    try:
        v_height = int(v.get("height") or 0)
    except Exception:
        v_height = 0
    try:
        a_channels = int(a.get("channels") or 0)
    except Exception:
        a_channels = 0
    try:
        max_h = int(os.getenv("TRANSCODE_MAX_HEIGHT", "1080") or "0")
    except Exception:
        max_h = 1080
    try:
        target_fps = float(os.getenv("TRANSCODE_FPS", "0") or "0")
    except Exception:
        target_fps = 0.0
    if not (target_fps and target_fps > 0):
        target_fps = 0.0

    copy_video = v_codec == "h264"
    copy_audio = a_codec in {"aac", "mp3"}
    do_scale = bool(max_h and max_h > 0 and v_height and v_height > max_h)

    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin"]
    if start and start > 0:
        cmd += ["-ss", f"{start:.3f}", "-noaccurate_seek"]

    if _is_http_url(input_value):
        cmd += [
            "-rw_timeout", "15000000",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "2",
        ]

    cmd += [
        "-analyzeduration",
        "10000000",
        "-probesize",
        "10000000",
        "-i",
        input_value,
        "-map",
        "0:v:0",
    ]
    if audio_stream is not None:
        cmd += ["-map", f"0:{int(audio_stream)}"]
    else:
        cmd += ["-map", "0:a:0?"]
    cmd += [
        "-sn",
        "-fflags",
        "+genpts",
        "-avoid_negative_ts",
        "make_zero",
        "-max_muxing_queue_size",
        "1024",
    ]

    if copy_video:
        cmd += ["-c:v", "copy"]
    else:
        do_fps = bool(target_fps and target_fps > 0)
        crf = "21" if do_scale else ("18" if v_height >= 1440 else "20")
        vf_parts = []
        if do_fps:
            vf_parts.append(f"fps={target_fps:g}")
        if do_scale:
            vf_parts.append(f"scale=-2:{max_h}:flags=fast_bilinear")
        vf = ",".join(vf_parts) if vf_parts else "null"
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
            "-vf",
            vf,
            "-crf",
            crf,
            "-pix_fmt",
            "yuv420p",
        ]

    if copy_audio:
        cmd += ["-c:a", "copy"]
    else:
        target_channels = 6 if a_channels >= 6 else 2
        target_bitrate = "384k" if target_channels == 6 else "192k"
        cmd += [
            "-c:a",
            "aac",
            "-b:a",
            target_bitrate,
            "-ac",
            str(target_channels),
            "-af",
            "aresample=async=1:first_pts=0",
        ]

    hls_time = "4"
    segment_pattern = os.path.join(sess_dir, "seg_%06d.ts")
    cmd += [
        "-f",
        "hls",
        "-hls_time",
        hls_time,
        "-hls_playlist_type",
        "event",
        "-hls_list_size",
        "0",
        "-hls_flags",
        "append_list+independent_segments",
        "-hls_segment_filename",
        segment_pattern,
        playlist_path,
    ]

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.DEVNULL,
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

    _HLS_SESSIONS[session_id] = {
        "dir": sess_dir,
        "playlist": playlist_path,
        "proc": proc,
        "last_access": time.time(),
        "input": input_value,
        "is_path": is_path,
        "start": start,
        "stderr_buf": stderr_buf,
        "stderr_task": stderr_task,
    }


@router.get("/hls")
async def hls(
    url: str | None = None,
    path: str | None = None,
    start: float = Query(default=0.0, ge=0.0),
    audio_stream: int | None = Query(default=None),
):
    if not url and not path:
        raise HTTPException(status_code=400, detail="url of path is verplicht")

    if float(start or 0.0) > 0.0:
        qs = []
        if path is not None:
            qs.append(f"path={urllib.parse.quote(path)}")
        if url is not None:
            qs.append(f"url={urllib.parse.quote(url)}")
        qs.append(f"start={urllib.parse.quote(str(float(start)))}")
        if audio_stream is not None:
            qs.append(f"audio_stream={audio_stream}")
        return RedirectResponse(url=f"/api/stream/play?{'&'.join(qs)}", status_code=302)

    is_path = path is not None
    input_value = _resolve_media_file(path) if is_path else urllib.parse.unquote(url)
    sid_seed = f"{input_value}|{float(start):.3f}|{os.getenv('TRANSCODE_MAX_HEIGHT','')}|{audio_stream or ''}"
    sid = hashlib.sha1(sid_seed.encode("utf-8", errors="ignore")).hexdigest()[:16]

    s = _HLS_SESSIONS.get(sid) or {}
    _HLS_SESSIONS[sid] = {
        **s,
        "input": input_value,
        "is_path": is_path,
        "start": float(start or 0.0),
        "audio_stream": audio_stream,
        "dir": os.path.join(_HLS_ROOT, sid),
        "playlist": os.path.join(_HLS_ROOT, sid, "index.m3u8"),
        "last_access": time.time(),
    }
    return RedirectResponse(url=f"/api/stream/hls/{sid}/index.m3u8", status_code=302)


@router.get("/hls/{session_id}/index.m3u8")
async def hls_index(session_id: str):
    _hls_cleanup()
    s = _HLS_SESSIONS.get(session_id)
    if not s:
        raise HTTPException(status_code=404, detail="Onbekende stream")

    s["last_access"] = time.time()
    await _ensure_hls_session(session_id, s.get("input"))
    playlist_path = _HLS_SESSIONS[session_id]["playlist"]

    try:
        start = float((_HLS_SESSIONS.get(session_id) or {}).get("start") or 0.0)
    except Exception:
        start = 0.0
    max_wait = 1200 if start > 0 else 500
    for _ in range(max_wait):
        if os.path.exists(playlist_path) and os.path.getsize(playlist_path) > 0:
            break
        await asyncio.sleep(0.1)

    if not os.path.exists(playlist_path) or os.path.getsize(playlist_path) == 0:
        sess = _HLS_SESSIONS.get(session_id) or {}
        proc = sess.get("proc")
        err = b""
        rc = None
        if proc:
            rc = proc.returncode
            if rc is None:
                try:
                    rc = await asyncio.wait_for(proc.wait(), timeout=0.1)
                except Exception:
                    rc = proc.returncode
        buf = sess.get("stderr_buf")
        if isinstance(buf, (bytes, bytearray)) and len(buf) > 0:
            err = bytes(buf)
        elif proc and proc.stderr:
            try:
                err = await asyncio.wait_for(proc.stderr.read(65536), timeout=0.2)
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
