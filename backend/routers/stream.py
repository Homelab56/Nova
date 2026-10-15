import httpx
import os
import json
import asyncio
import urllib.parse
import hashlib
import time
import shutil
import mimetypes
import math
import struct
import re
import tempfile
from datetime import datetime, timezone
from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import StreamingResponse, FileResponse, RedirectResponse, Response
from pydantic import BaseModel
from .config_loader import get_rd_token, get_opensubtitles_key, get_opensubtitles_credentials

router = APIRouter()

RD_BASE = "https://api.real-debrid.com/rest/1.0"

_HLS_ROOT = "/tmp/nova_hls"
_HLS_SESSIONS: dict[str, dict] = {}
_LAST_START: dict[str, tuple[float, float]] = {}

# OpenSubtitles' free tier caps downloads (5/24h). Once we hit that cap we
# remember the reset time it reports, so we skip the doomed search+download
# round-trip (and the extra hit against their rate limiter) until then.
_OS_QUOTA_RESET_AT: float = 0.0


def _os_quota_active() -> bool:
    return time.time() < _OS_QUOTA_RESET_AT

_ALLOWED_LANG_PREFIXES = (
    "en", "eng", "english", "engels",
    "nl", "nld", "dut", "vla", "vlaams", "flemish", "nederlands",
)


def _norm_lang(s: str) -> str:
    return (s or "").lower().strip().replace("_", "-")


def _lang_class(language: str, title: str = "") -> str:
    """"en" | "nl" | "und" (geen taalinfo) | "other". Taal-tag gaat voor; enkel bij
    ontbrekende/"und" tag telt de titel, en dan als heel woord (losse substring-matches
    liet anderstalige sporen, bv. Spaans, als Engels doorgaan)."""
    l = _norm_lang(language)
    if l and l not in {"und", "unk", "mis", "zxx"}:
        base = l.split("-")[0]
        if base in {"en", "eng"}:
            return "en"
        if base in {"nl", "nld", "dut", "vla"}:
            return "nl"
        return "other"
    t = _norm_lang(title)
    if re.search(r"(english|engels|eng)", t):
        return "en"
    if re.search(r"(nederlands|dutch|vlaams|flemish|nld|dut)", t):
        return "nl"
    if t and re.search(r"(spanish|espanol|español|castellano|latino|french|francais|german|deutsch|italian|italiano|portuguese|russian|japanese|korean|chinese)", t):
        return "other"
    return "und"


def _is_allowed_lang(language: str, title: str = "") -> bool:
    return _lang_class(language, title) != "other"


def _default_audio_stream(streams: list[dict]) -> dict | None:
    """Gesproken taal moet altijd Engels of Nederlands zijn (nooit zomaar het eerste
    spoor). Voorkeur en > nl (meeste kanalen), dan sporen zonder taalinfo."""
    audio = [x for x in streams if isinstance(x, dict) and x.get("codec_type") == "audio"]

    def tags_of(x):
        t = x.get("tags") or {}
        return (t.get("language") or "", t.get("title") or "") if isinstance(t, dict) else ("", "")

    def ch(x):
        try:
            return int(x.get("channels") or 0)
        except Exception:
            return 0

    for cls in ("en", "nl", "und"):
        hits = [x for x in audio if _lang_class(*tags_of(x)) == cls]
        if hits:
            return max(hits, key=ch)
    return None


def _resolve_audio(streams: list[dict], audio_stream: int | None) -> tuple[dict, int | None]:
    """Geeft (audio-stream-dict, stream-index) terug. Expliciete keuze wint; anders
    het beste Engels/Nederlands spoor (zie _default_audio_stream); anders het eerste."""
    audio = [x for x in streams if isinstance(x, dict) and x.get("codec_type") == "audio"]
    if audio_stream is not None:
        chosen = next((x for x in audio if x.get("index") == int(audio_stream)), None)
        return (chosen or {}), audio_stream
    best = _default_audio_stream(streams)
    if best is not None and best.get("index") is not None:
        return best, int(best["index"])
    return (audio[0] if audio else {}), None


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

async def _ffprobe_duration_only(input_value: str, timeout_secs: float = 10.0) -> tuple[float, list[str]]:
    """
    Snelle ffprobe-check die de duur (en, gratis in dezelfde probe, de audio-
    codec(s)) opvraagt, met een klein probesize/analyzeduration. Zowel de
    containerduur als de streaminfo staan doorgaans al in de eerste paar
    KB-MB van een geldig MKV/MP4-bestand, dus dit hoeft niet - in
    tegenstelling tot _ffprobe_probe_health, dat ook ondertitelsporen diep
    in het bestand moet vinden - het hele bestand te scannen. Daardoor
    blijft dit ook voor grote 4K-bronnen ruim binnen een korte timeout.
    De audio-codec is de betrouwbare manier om bv. TrueHD uit te sluiten:
    op naam filteren (_looks_like_junk_release) mist releases die het
    (vaak bij BDRemuxes) simpelweg niet in de bestandsnaam vermelden.
    Geeft (0.0, []) terug als er niets bepaald kon worden.
    """
    http = _is_http_url(input_value)
    args = ["ffprobe", "-v", "error", "-show_entries",
            "format=duration:stream=codec_name,codec_type", "-of", "json"]
    if http:
        args.extend([
            "-rw_timeout", "8000000",
            "-timeout", "8000000",
            "-user_agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            "-headers", "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36\r\nAccept: */*\r\nConnection: keep-alive\r\n",
            "-analyzeduration", "5000000",
            "-probesize", "5000000",
        ])
    args.append(input_value)
    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout_secs)
        if proc.returncode != 0:
            msg = (err or b"").decode("utf-8", errors="ignore").strip() or "geen stderr"
            print(f"ffprobe duration failed for {input_value[:120]}: returncode {proc.returncode}: {msg[:400]}")
            return 0.0, []
        data = json.loads(out.decode("utf-8", errors="ignore") or "{}")
        try:
            duration = float((data.get("format") or {}).get("duration") or 0.0)
        except (TypeError, ValueError):
            duration = 0.0
        streams = data.get("streams") or []
        audio_codecs = [
            (s.get("codec_name") or "").lower()
            for s in streams if isinstance(s, dict) and s.get("codec_type") == "audio"
        ]
        return duration, audio_codecs
    except Exception as e:
        print(f"FFProbe duration fout voor {input_value[:120]}: {e}")
        return 0.0, []


async def _ffprobe_probe_health(input_value: str, is_path: bool) -> tuple[float, list[dict]]:
    """
    Zoals _ffprobe_subtitle_streams, maar haalt ook de duur van de bron op.
    AIOStreams serveert voor niet (meer) beschikbare bronnen soms een kort
    placeholder-clipje i.p.v. de echte video (bv. "wordt nog gedownload" of
    "unavailable for legal reasons") - dat lijkt qua ffprobe verder op een
    geldig bestand, maar duurt hooguit een paar seconden. Duur teruggeven
    zodat zulke bronnen herkend en uitgesloten kunnen worden, ongeacht de
    exacte foutmelding die AIOStreams toont (die varieert).
    Geeft (duration_secs, subtitle_streams) terug; duration_secs is 0.0 als
    de duur niet bepaald kon worden.
    """
    http = _is_http_url(input_value)
    args = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration:stream=index,codec_name,codec_type:stream_tags=language,title",
        "-of",
        "json",
    ]
    if http:
        args.extend([
            "-rw_timeout", "15000000",
            "-timeout", "15000000",
            "-user_agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            "-headers", "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36\r\nAccept: */*\r\nConnection: keep-alive\r\n",
            # Ondertitelsporen worden net als de duur al gedeclareerd in de
            # containerheader (MKV "Tracks"-element, meteen na Segment Info) -
            # dus dit hoeft niet diep in het bestand te zoeken. De vorige,
            # veel grotere waarde (120MB/120s) liet dit voor grote 4K-bronnen
            # geregeld de buitenste timeout van de caller overschrijden,
            # waardoor zulke bronnen onterecht als "kapot" werden behandeld.
            "-analyzeduration", "15000000",
            "-probesize", "15000000",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
        ])
    args.append(input_value)

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
            print(f"ffprobe health failed for {input_value[:120]}: returncode {proc.returncode}: {msg[:400]}")
            return 0.0, []
        data = json.loads(out.decode("utf-8", errors="ignore") or "{}")
        try:
            duration = float((data.get("format") or {}).get("duration") or 0.0)
        except (TypeError, ValueError):
            duration = 0.0
        streams = data.get("streams") or []
        subtitle_streams = [s for s in streams if isinstance(s, dict) and s.get("codec_type") == "subtitle"]
        return duration, subtitle_streams
    except Exception as e:
        print(f"FFProbe health fout voor {input_value[:120]}: {e}")
        return 0.0, []


async def _ffprobe_subtitle_streams(input_value: str, is_path: bool) -> list[dict]:
    http = _is_http_url(input_value)
    args = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "s",
        "-show_entries",
        "stream=index,codec_name:stream_tags=language,title:stream_disposition=forced,hearing_impaired",
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
        "stream=index,codec_type,codec_name,width,height,channels:stream_tags=language,title",
        "-of",
        "json",
        input_value,
    ]
    if _is_http_url(input_value):
        # Moet NA "-v error" (index 3) - op index 4 stond de optie midden tussen
        # "-show_entries" en zijn waarde, waardoor ffprobe voor elke http-bron faalde
        # (lege probe -> hoogte 0 en geen audio-keuze).
        args.insert(3, "5000000")
        args.insert(3, "-rw_timeout")
    if is_path:
        args[-1] = input_value

    proc = None
    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        # Grote 4K/HDR/DV-bronnen over een (trage) debrid-link hebben soms meer dan
        # de oorspronkelijke 8s nodig om te analyseren - een timeout hier liet de
        # resolutie-check stilletjes falen (hoogte=0), wat de 1080p-transcode-cap
        # uitschakelde i.p.v. hem te laten gelden (zie do_scale hierboven/verderop).
        out, _err = await asyncio.wait_for(proc.communicate(), timeout=15)
        if proc.returncode != 0: return {}
        return json.loads(out.decode("utf-8"))
    except Exception as e:
        print(f"FFProbe streams fout: {e}")
        if proc is not None:
            try:
                proc.kill()
            except Exception:
                pass
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
    a, audio_stream = _resolve_audio(streams, audio_stream)
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
        # Onbekende hoogte (ffprobe gaf niks terug, bv. door timeout op een grote
        # 4K/HDR/DV-bron over een trage debrid-link) moet voorzichtig behandeld
        # worden als "kan 4K zijn" i.p.v. "geen schaling nodig" - anders probeert
        # ultrafast x264 een onbekende, mogelijk 4K-bron realtime te encoderen
        # zonder de 1080p-veiligheidscap, wat de CPU niet bijhoudt (hapering).
        do_scale = bool(max_h and max_h > 0) and (not v_height or v_height > max_h)
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
        now = time.time()
        # Verlopen items nooit actief opgeruimd - groeide anders onbeperkt mee
        # met elke unieke client/pad-combinatie die ooit met een starttijd
        # werd afgespeeld, ook lang nadat de 45s-relevantievenster verstreken is.
        for k, (ts, _) in list(_LAST_START.items()):
            if now - ts > 45:
                _LAST_START.pop(k, None)
        key = f"{client_host}|{'path' if is_path else 'url'}|{path or url or ''}"
        _LAST_START[key] = (now, float(start))

    return StreamingResponse(
        _stream_with_semaphore(),
        media_type="video/mp4",
        headers={
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        },
    )


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
# zoeken/downloaden/synchroniseren. _SUB_CACHE_VERSION zit in de cache-key
# verwerkt: verhoog deze bij een wijziging aan de sync-logica zelf (ffsubsync-
# parameters, referentie-venster, kandidaat-selectie, ...), anders blijven
# oude, met de vorige logica gesynchroniseerde resultaten hangen.
_SUB_CACHE_DIR = "/app/data/subtitles_cache"
_SUB_CACHE_VERSION = "v13"


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


# VIP-quota (hogere daglimiet dan de kale API-key alleen geeft) is
# gekoppeld aan het account, niet aan de API-key - dus enkel de key
# meesturen volstaat niet, er moet ook ingelogd worden. Token 24u geldig
# volgens OpenSubtitles' eigen documentatie; hier voor de zekerheid 20u
# gecached en dan proactief vernieuwd.
_OS_LOGIN_TOKEN: str | None = None
_OS_LOGIN_EXPIRES_AT: float = 0
_OS_LOGIN_LOCK = asyncio.Lock()
# Bij een mislukte login (verkeerde inloggegevens, rate limit, ...) een tijdje
# niet opnieuw proberen - anders vuurt elke aparte subtitle-aanroep binnen
# hetzelfde verzoek (zoeken + downloaden, x meerdere kandidaten) meteen een
# nieuwe poging af, wat zelf al tegen OpenSubtitles' eigen loginlimiet
# ("1 req/sec per IP") aanloopt.
_OS_LOGIN_RETRY_AFTER: float = 0


async def _os_login() -> str | None:
    global _OS_LOGIN_TOKEN, _OS_LOGIN_EXPIRES_AT, _OS_LOGIN_RETRY_AFTER
    now = time.time()
    if _OS_LOGIN_TOKEN and now < _OS_LOGIN_EXPIRES_AT:
        return _OS_LOGIN_TOKEN
    if now < _OS_LOGIN_RETRY_AFTER:
        return None
    async with _OS_LOGIN_LOCK:
        if _OS_LOGIN_TOKEN and time.time() < _OS_LOGIN_EXPIRES_AT:
            return _OS_LOGIN_TOKEN
        if time.time() < _OS_LOGIN_RETRY_AFTER:
            return None
        username, password = get_opensubtitles_credentials()
        if not username or not password:
            return None
        try:
            async with httpx.AsyncClient(timeout=15) as client:
                r = await client.post(
                    f"{_OS_BASE}/login",
                    json={"username": username, "password": password},
                    headers={
                        "Api-Key": get_opensubtitles_key(),
                        "User-Agent": _OS_USER_AGENT,
                        "Content-Type": "application/json",
                    },
                )
            if r.status_code != 200:
                print(f"OpenSubtitles login mislukt: {r.status_code} {r.text[:300]}")
                # 5 min wachten bij een fout wachtwoord/gebruikersnaam, 30s bij
                # een rate limit (die is snel weer voorbij).
                _OS_LOGIN_RETRY_AFTER = time.time() + (30 if r.status_code == 429 else 300)
                return None
            token = r.json().get("token")
            if not token:
                _OS_LOGIN_RETRY_AFTER = time.time() + 300
                return None
            _OS_LOGIN_TOKEN = token
            _OS_LOGIN_EXPIRES_AT = time.time() + 20 * 3600
            return token
        except Exception as e:
            print(f"OpenSubtitles login fout: {e}")
            _OS_LOGIN_RETRY_AFTER = time.time() + 60
            return None


async def _os_headers() -> dict:
    headers = {
        "Api-Key": get_opensubtitles_key(),
        "User-Agent": _OS_USER_AGENT,
        "Content-Type": "application/json",
    }
    # Als geen gebruiker/wachtwoord ingesteld is (of inloggen mislukt) valt
    # dit gewoon terug op anonieme toegang i.p.v. helemaal te breken - VIP-
    # quota is dan enkel niet van toepassing.
    token = await _os_login()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def _release_tokens(release: str) -> set[str]:
    toks = set(re.findall(r"[a-z0-9]+", urllib.parse.unquote_plus(release or "").lower()))
    return {t for t in toks if len(t) >= 3 and t not in {"mkv", "mp4", "avi", "the", "and"}}


def _score_subtitle(attrs: dict, rel_tokens: set[str]) -> float:
    """Rangschikt kandidaten op hoe waarschijnlijk ze bij EXACT dit bestand horen:
    moviehash-match (bit-exact zelfde bestand) >> overeenkomende release-tokens
    (resolutie, bron, groep) > vertrouwde uploader > populariteit. Een populaire maar
    andere montage geeft anders structureel drift."""
    score = 0.0
    if attrs.get("moviehash_match"):
        score += 1000
    toks = _release_tokens(attrs.get("release") or "")
    if rel_tokens:
        score += 100.0 * len(toks & rel_tokens) / len(rel_tokens)
    if attrs.get("from_trusted"):
        score += 15
    dl = attrs.get("download_count") or 0
    score += min(20.0, 5.0 * math.log10(1 + max(0, dl)))
    if attrs.get("hearing_impaired"):
        score -= 10
    return score


async def _search_opensubtitles(
    tmdb_id: int, media_type: str, language: str, season: int | None, episode: int | None,
    max_candidates: int = 4, release: str = "", moviehash: str | None = None,
) -> list[dict]:
    """Geeft de beste [max_candidates] kandidaten terug (zie _score_subtitle), zodat de
    caller een volgende kan proberen als de beste niet lukt of niet betrouwbaar
    synchroniseert."""
    if not get_opensubtitles_key():
        return []
    base: dict = {
        "tmdb_id": tmdb_id, "languages": language,
        "ai_translated": "exclude", "machine_translated": "exclude",
    }
    if moviehash:
        base["moviehash"] = moviehash
    if media_type == "tv" and season and episode:
        base["season_number"] = season
        base["episode_number"] = episode
    rel_tokens = _release_tokens(release)

    async def query(params: dict) -> list[dict]:
        async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
            r = await client.get(f"{_OS_BASE}/subtitles", params=params, headers=await _os_headers())
        if r.status_code != 200:
            print(f"OpenSubtitles zoekfout: {r.status_code} {r.text[:300]}")
            return []
        return (r.json().get("data")) or []

    try:
        items = await query({**base, "hearing_impaired": "exclude"})
        if not items:
            items = await query(base)
        scored = []
        for item in items:
            attrs = item.get("attributes") or {}
            files = attrs.get("files") or []
            if files and files[0].get("file_id"):
                scored.append((_score_subtitle(attrs, rel_tokens), {
                    "file_id": files[0]["file_id"],
                    "moviehash_match": bool(attrs.get("moviehash_match")),
                    "release": attrs.get("release") or "",
                }))
        scored.sort(key=lambda x: x[0], reverse=True)
        return [c for _, c in scored[:max_candidates]]
    except Exception as e:
        print(f"OpenSubtitles zoekfout: {e}")
        return []


async def _download_opensubtitles(file_id: int) -> str | None:
    # Ruwe SRT lokaal bewaren: spaart de (beperkte) OpenSubtitles-downloadquota bij
    # herberekeningen (nieuwe sync-logica) en maakt sync-diagnose mogelijk.
    raw_path = os.path.join(_SUB_CACHE_DIR, f"raw_{file_id}.srt")
    try:
        if os.path.exists(raw_path):
            with open(raw_path, "r", encoding="utf-8", errors="ignore") as f:
                return f.read()
    except Exception:
        pass
    text = await _download_opensubtitles_remote(file_id)
    if text:
        try:
            os.makedirs(_SUB_CACHE_DIR, exist_ok=True)
            with open(raw_path, "w", encoding="utf-8") as f:
                f.write(text)
        except Exception:
            pass
    return text


async def _download_opensubtitles_remote(file_id: int) -> str | None:
    try:
        async with httpx.AsyncClient(timeout=20, follow_redirects=True) as client:
            r = await client.post(f"{_OS_BASE}/download", json={"file_id": file_id}, headers=await _os_headers())
        if r.status_code != 200:
            print(f"OpenSubtitles downloadfout: {r.status_code} {r.text[:300]}")
            if r.status_code == 406:
                try:
                    reset_iso = r.json().get("reset_time_utc")
                    if reset_iso:
                        global _OS_QUOTA_RESET_AT
                        _OS_QUOTA_RESET_AT = datetime.fromisoformat(
                            reset_iso.replace("Z", "+00:00")
                        ).timestamp()
                except Exception:
                    pass
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


async def _osdb_hash(url: str) -> str | None:
    """OpenSubtitles' 'moviehash' van het bestand achter [url]: bestandsgrootte + som van
    de eerste en laatste 64KB. Een match betekent dat de ondertitel bit-exact voor DIT
    bestand gemaakt is (geen montageverschil mogelijk). Leest enkel 2x64KB via
    Range-requests; None als de bron geen Range ondersteunt."""
    chunk = 65536

    async def read_range(client: httpx.AsyncClient, rng: str) -> tuple[bytes, int | None]:
        async with client.stream("GET", url, headers={"Range": rng}) as r:
            if r.status_code != 206:
                return b"", None
            cr = r.headers.get("content-range", "")
            total = cr.rsplit("/", 1)[-1]
            size = int(total) if total.isdigit() else None
            buf = b""
            async for part in r.aiter_bytes():
                buf += part
                if len(buf) >= chunk:
                    break
            return buf[:chunk], size

    try:
        async with httpx.AsyncClient(timeout=20, follow_redirects=True) as client:
            head, size = await read_range(client, f"bytes=0-{chunk - 1}")
            if not size or size < chunk * 2 or len(head) < chunk:
                return None
            tail, _ = await read_range(client, f"bytes={size - chunk}-{size - 1}")
            if len(tail) < chunk:
                return None
        h = size
        for buf in (head, tail):
            for (v,) in struct.iter_unpack("<Q", buf):
                h = (h + v) & 0xFFFFFFFFFFFFFFFF
        return f"{h:016x}"
    except Exception as e:
        print(f"moviehash fout: {e}")
        return None


_SRT_TS = r"(\d+):(\d{2}):(\d{2})[,.](\d{1,3})"


def _srt_parse(text: str) -> list[list]:
    """SRT -> [[start_s, end_s, tekst], ...] (ook tolerant voor punt i.p.v. komma)."""
    text = (text or "").replace("\r\n", "\n").replace("\r", "\n").lstrip("\ufeff")
    cues = []
    for block in re.split(r"\n\s*\n", text.strip()):
        lines = block.split("\n")
        for i, line in enumerate(lines):
            m = re.match(rf"\s*{_SRT_TS}\s*-->\s*{_SRT_TS}", line)
            if not m:
                continue
            g = m.groups()
            start = int(g[0]) * 3600 + int(g[1]) * 60 + int(g[2]) + int(g[3].ljust(3, "0")) / 1000
            end = int(g[4]) * 3600 + int(g[5]) * 60 + int(g[6]) + int(g[7].ljust(3, "0")) / 1000
            body = "\n".join(lines[i + 1:]).strip()
            if body:
                cues.append([start, end, body])
            break
    return cues


def _fmt_ts(sec: float, sep: str) -> str:
    ms = max(0, int(round(sec * 1000)))
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d}{sep}{ms % 1000:03d}"


def _cues_to_srt(cues: list[list]) -> str:
    return "\n".join(
        f"{i}\n{_fmt_ts(c[0], ',')} --> {_fmt_ts(c[1], ',')}\n{c[2]}\n" for i, c in enumerate(cues, 1)
    )


def _cues_to_vtt(cues: list[list]) -> str:
    body = "\n".join(f"{_fmt_ts(c[0], '.')} --> {_fmt_ts(c[1], '.')}\n{c[2]}\n" for c in cues)
    return "WEBVTT\n\n" + body


_SYNC_WINDOW_PAD = 60.0     # cues vanaf [venster - PAD] meenemen (ondertitel mag vóór de audio staan)
_SYNC_MAX_OFFSET = 100.0    # ffsubsync zoekt offsets binnen +-100s (=> echt bereik -40s .. +160s)


async def _extract_audio_window(
    input_value: str, out_path: str, start: float, dur: float, audio_idx: int | None, timeout: float = 150.0
) -> bool:
    cmd = ["nice", "-n", "10", "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin"]
    if _is_http_url(input_value):
        cmd += ["-rw_timeout", "20000000", "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "3"]
    cmd += ["-ss", f"{start:.3f}", "-i", input_value, "-t", f"{dur:.3f}"]
    cmd += ["-map", f"0:{audio_idx}" if audio_idx is not None else "0:a:0?"]
    cmd += ["-vn", "-sn", "-ac", "1", "-ar", "16000", "-acodec", "pcm_s16le", "-y", out_path]
    proc = None
    try:
        proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        _o, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        if proc.returncode != 0 or not os.path.exists(out_path) or os.path.getsize(out_path) < 32000:
            print(f"Audio-venster extractie mislukt: {(err or b'').decode('utf-8', errors='ignore')[:300]}")
            return False
        return True
    except asyncio.TimeoutError:
        if proc:
            try:
                proc.kill()
            except Exception:
                pass
        print("Audio-venster extractie: timeout")
        return False
    except Exception as e:
        print(f"Audio-venster extractie fout: {e}")
        return False


async def _window_offset(
    input_value: str, cues: list[list], t0: float, win: float, audio_idx: int | None,
    center: float = 0.0, pad: float = _SYNC_WINDOW_PAD, max_off: float = _SYNC_MAX_OFFSET,
) -> float | None:
    """Meet de offset (audio_tijd - ondertitel_tijd) in één venster: audio van [t0, t0+win]
    tegen de cues rond dat moment. Enkel een pure verschuiving (--no-fix-framerate):
    drift/montageverschillen volgen uit het verschil tussen vensters. Met [center] worden de
    cues eerst met die waarde voorverschoven zodat ffsubsync slechts een smal bereik
    (+-max_off) rond de verwachte offset hoeft af te zoeken - veel minder vals-positieven
    dan blind +-100s zoeken op actiefilms vol muziek."""
    base = t0 - pad
    subset = [
        [c[0] + center - base, c[1] + center - base, c[2]]
        for c in cues
        if t0 - pad <= c[0] + center <= t0 + win + max_off and c[0] + center - base >= 0
    ]
    if len(subset) < 8:
        return None
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "win.wav")
        if not await _extract_audio_window(input_value, wav, t0, win, audio_idx):
            return None
        in_path, out_path = os.path.join(tmp, "in.srt"), os.path.join(tmp, "out.srt")
        with open(in_path, "w", encoding="utf-8") as f:
            f.write(_cues_to_srt(subset))
        cmd = [
            "nice", "-n", "10", "ffsubsync", wav, "-i", in_path, "-o", out_path,
            "--no-fix-framerate", "--max-offset-seconds", str(int(max_off)),
        ]
        proc = None
        try:
            proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            _o, err = await asyncio.wait_for(proc.communicate(), timeout=120.0)
            if proc.returncode != 0 or not os.path.exists(out_path):
                print(f"ffsubsync venster {t0:.0f}s mislukt: {(err or b'').decode('utf-8', errors='ignore')[-300:]}")
                return None
            with open(out_path, "r", encoding="utf-8", errors="ignore") as f:
                out = _srt_parse(f.read())
        except asyncio.TimeoutError:
            if proc:
                try:
                    proc.kill()
                except Exception:
                    pass
            print(f"ffsubsync venster {t0:.0f}s: timeout")
            return None
        except Exception as e:
            print(f"ffsubsync venster {t0:.0f}s fout: {e}")
            return None
    if len(out) < len(subset) // 2:
        return None
    diffs = sorted(o[0] - i[0] for o, i in zip(out, subset))
    off_prime = diffs[len(diffs) // 2]
    # Een resultaat tegen de rand van het zoekbereik is geen echte match.
    if abs(off_prime) >= max_off - 0.5:
        return None
    return center + off_prime + pad


def _pick_window_starts(duration: float, is_tv: bool, win: float, fracs: list[float] | None = None) -> list[float]:
    d = duration if duration > 0 else (2700.0 if is_tv else 6600.0)
    if fracs is None:
        fracs = [0.08, 0.30, 0.55, 0.80] if d > 1800 else [0.20, 0.55]
    starts: list[float] = []
    for f in fracs:
        t0 = max(120.0, d * f)
        if t0 + win > d - 60:
            t0 = max(0.0, d - win - 60)
        if all(abs(t0 - x) > win for x in starts):
            starts.append(t0)
    return starts


_TEXT_SUB_CODECS = {"subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"}


async def _pick_reference_subtitle(input_value: str) -> int | None:
    """Stream-index van een ingebakken TEKST-ondertitel (Engels > Nederlands > andere; geen
    forced/SDH). Die loopt per definitie exact synchroon met het beeld van dit bestand en
    is een veel betere ijkpunt dan spraakdetectie op de audio (muziek/actie telt daar
    als spraak mee en geeft ruis van meerdere seconden)."""
    streams = await _ffprobe_subtitle_streams(input_value, is_path=False)
    best = None
    for st_ in streams:
        if (st_.get("codec_name") or "").lower() not in _TEXT_SUB_CODECS:
            continue
        tags = st_.get("tags") or {}
        disp = st_.get("disposition") or {}
        lang = _norm_lang(tags.get("language") or "")
        title = (tags.get("title") or "").lower()
        if disp.get("forced") or disp.get("hearing_impaired") or "forced" in title or "sdh" in title or "commentary" in title:
            continue
        rank = 0 if lang.split("-")[0] in {"en", "eng"} else 1 if lang.split("-")[0] in {"nl", "nld", "dut"} else 2
        if "british" in title:
            rank += 0.5
        if best is None or rank < best[0]:
            best = (rank, int(st_["index"]))
    return best[1] if best else None


async def _extract_sub_window(input_value: str, t0: float, win: float, idx: int, timeout: float = 150.0) -> list[list] | None:
    """Cues van ingebakken ondertitelstream [idx] in [t0, t0+win] (absolute filmtijd)."""
    with tempfile.TemporaryDirectory() as tmp:
        out_path = os.path.join(tmp, "ref.srt")
        cmd = ["nice", "-n", "10", "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin"]
        if _is_http_url(input_value):
            cmd += ["-rw_timeout", "20000000", "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "3"]
        cmd += ["-ss", f"{t0:.3f}", "-i", input_value, "-t", f"{win:.3f}", "-map", f"0:{idx}",
                "-vn", "-an", "-c:s", "srt", "-f", "srt", "-y", out_path]
        proc = None
        try:
            proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            _o, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
            if proc.returncode != 0 or not os.path.exists(out_path):
                print(f"Referentie-ondertitel venster {t0:.0f}s mislukt: {(err or b'').decode('utf-8', errors='ignore')[:200]}")
                return None
            with open(out_path, "r", encoding="utf-8", errors="ignore") as f:
                cues = _srt_parse(f.read())
        except asyncio.TimeoutError:
            if proc:
                try:
                    proc.kill()
                except Exception:
                    pass
            print(f"Referentie-ondertitel venster {t0:.0f}s: timeout")
            return None
        except Exception as e:
            print(f"Referentie-ondertitel venster {t0:.0f}s fout: {e}")
            return None
    return [[c[0] + t0, c[1] + t0, c[2]] for c in cues]


def _text_grams(text: str) -> set[str]:
    """Karakter-trigrammen van de woorden (>=3 letters): Engels en Nederlands delen veel
    eigennamen, cijfers en verwante woorden (calibration/kalibratie, data/datacentrum)."""
    t = re.sub(r"[^a-z0-9 ]", "", (text or "").lower().replace("\n", " "))
    grams: set[str] = set()
    for w in t.split():
        if len(w) < 3:
            continue
        w = f"^{w}$"
        grams.update(w[i:i + 3] for i in range(len(w) - 2))
    return grams


def _text_sim_scan(ref_cues: list[list], cues: list[list], t0: float, win: float, max_off: float, step: float = 0.25):
    """Score per offset (-max_off..max_off): som van de tekstovereenkomst van regelparen
    (referentie vs. te synchroniseren ondertitel) die na verschuiving binnen ~2s van elkaar
    beginnen. Anders dan alleen ritme (onsets) kijkt dit naar de INHOUD - dat onderscheidt de
    juiste piek van een zijpiek één regel verderop. Geeft (offsets, scores) of None."""
    import numpy as np

    lo, hi = t0 - max_off - 10, t0 + win + max_off + 10
    near = [(c[0], _text_grams(c[2])) for c in cues if lo <= c[0] <= hi]
    pairs = []
    for r in ref_cues:
        rg = _text_grams(r[2])
        if len(rg) < 4:
            continue
        for ns, ng in near:
            if abs(r[0] - ns) <= max_off + 8 and ng:
                sim = 2 * len(rg & ng) / (len(rg) + len(ng))
                if sim >= 0.30:  # alleen duidelijk verwante paren
                    pairs.append((r[0] - ns, sim))  # impliciete offset van dit paar
    if len(pairs) < 3:
        return None
    offs = np.arange(-max_off, max_off + step / 2, step)
    scores = np.zeros(len(offs), dtype=np.float32)
    for o_pair, sim in pairs:
        # paar draagt bij rond zijn eigen offset (gauss, sigma 0.8s, +-2s)
        d = (offs - o_pair)
        mask = np.abs(d) <= 2.0
        scores[mask] += sim * np.exp(-0.5 * (d[mask] / 0.8) ** 2)
    return offs, scores


def _ref_offset_candidates(
    ref_cues: list[list], cues: list[list], t0: float, win: float, center: float, max_off: float, n_best: int = 4
) -> list[tuple[float, float]]:
    """Kandidaat-offsets (referentietijd - ondertitel-tijd, score 0..2) voor één venster.
    Kandidaten komen uit kruiscorrelatie van de BEGINMOMENTEN van de ondertitelregels
    (scherp, maar ritmische dialoog geeft zijpieken ~3s verderop); de score combineert die
    piekhoogte met de inhoudelijke tekstovereenkomst bij die offset (_text_sim_scan), zodat
    de juiste piek wint. De uiteindelijke keuze gebeurt over alle vensters heen
    (_pick_offset_path)."""
    import numpy as np

    dt = 0.1
    if len(ref_cues) < 8:
        return []
    sigma = 0.4
    kx = np.arange(-1.5, 1.5 + dt / 2, dt)
    kernel = np.exp(-0.5 * (kx / sigma) ** 2).astype(np.float32)

    def signal(events, t_start, n):
        sig = np.zeros(n, dtype=np.float32)
        for t, w in events:
            i = int(round((t - t_start) / dt))
            if 0 <= i < n:
                sig[i] += w
        return np.convolve(sig, kernel, mode="same")

    n_ref = int(win / dt)
    ref = signal([(c[0], 1.0) for c in ref_cues] + [(c[1], 0.5) for c in ref_cues], t0, n_ref)
    if float(ref.sum()) < 10:
        return []
    t_s = t0 - (center + max_off)
    t_e = t0 + win - (center - max_off)
    n_d = int((t_e - t_s) / dt) + 2
    if n_d <= n_ref:
        return []
    dut = signal([(c[0], 1.0) for c in cues] + [(c[1], 0.5) for c in cues], t_s, n_d)
    corr = np.correlate(dut, ref, mode="valid")  # corr[k] = sum_i dut[k+i] * ref[i]
    top = float(corr.max())
    if top <= 0:
        return []
    guard = int(1.2 / dt)
    picks: list[tuple[int, float]] = []
    for idx in np.argsort(corr)[::-1]:
        if all(abs(int(idx) - p_) > guard for p_, _ in picks):
            picks.append((int(idx), float(corr[idx])))
        if len(picks) >= n_best:
            break
    cands = [((t0 - t_s) - k * dt, v / top) for k, v in picks]

    scan = _text_sim_scan(ref_cues, cues, t0, win, max_off + abs(center))
    if scan is not None:
        offs, sc = scan
        smax = float(sc.max())
        if smax >= 0.8:  # genoeg inhoudelijk bewijs; anders neutraal (alleen ritme)
            out = []
            for o, base in cands:
                m = np.abs(offs - o) <= 0.75
                sim_rel = float(sc[m].max()) / smax if m.any() else 0.0
                out.append((o, base + 1.0 * sim_rel))
            # ook de sterkste inhoudelijke piek zelf als kandidaat (ritme kan 'm missen)
            j = int(np.argmax(sc))
            if all(abs(offs[j] - o) > 1.2 for o, _ in out):
                out.append((float(offs[j]), 0.6 + 1.0))
            return sorted(out, key=lambda x: -x[1])[:n_best + 1]
    return cands


def _pick_offset_path(windows: list[tuple[float, list[tuple[float, float]]]]) -> list[tuple[float, float]]:
    """windows = [(sub-tijd van het venster, [(offset, score), ...])] in tijdsvolgorde. Kiest via
    dynamic programming per venster de kandidaat zodat de som van scores hoog is en de offset
    tussen opeenvolgende vensters vloeiend verloopt (echte drift is traag; een zijpiek
    springt ~3s heen en weer). Sprongen blijven mogelijk (begrensde straf) voor echte
    montageverschillen."""
    lam, cap = 0.04, 6.0
    ws = [w for w in windows if w[1]]
    if not ws:
        return []
    best = [[sc for _, sc in ws[0][1]]]
    back: list[list[int]] = [[-1] * len(ws[0][1])]
    for i in range(1, len(ws)):
        row, brow = [], []
        for off, sc in ws[i][1]:
            cands = [
                best[i - 1][j] - lam * min(abs(off - po), cap)
                for j, (po, _) in enumerate(ws[i - 1][1])
            ]
            j = max(range(len(cands)), key=cands.__getitem__)
            row.append(sc + cands[j])
            brow.append(j)
        best.append(row)
        back.append(brow)
    j = max(range(len(best[-1])), key=best[-1].__getitem__)
    path = []
    for i in range(len(ws) - 1, -1, -1):
        path.append((ws[i][0], ws[i][1][j][0]))
        j = back[i][j]
    path.reverse()
    return path


def _robust_line(anchors: list[tuple[float, float]], duration: float, tol: float = 1.8):
    """RANSAC-achtige lijn door (ondertitel-tijd, offset): kies de lijn met de meeste ankers
    binnen [tol] seconden en fit die opnieuw op die ankers. Uitschieters (valse pieken) vallen
    zo af. Geeft (offset_functie, beschrijving, n_inliers) of None."""
    n = len(anchors)
    if n < 3:
        return None
    best = None
    for i in range(n):
        for j in range(i + 1, n):
            k0, o0 = anchors[i]
            k1, o1 = anchors[j]
            if k1 - k0 < 300:
                continue
            slope = (o1 - o0) / (k1 - k0)
            if abs(slope) > 0.05:      # >5% tempoverschil is geen realistische drift
                continue
            icpt = o0 - slope * k0
            inl = [a for a in anchors if abs(a[1] - (icpt + slope * a[0])) <= tol]
            if best is None or len(inl) > len(best):
                best = inl
    if best is None or len(best) < max(3, int(0.6 * n + 0.5)):
        return None
    ks = [a[0] for a in best]
    os_ = [a[1] for a in best]
    m = len(best)
    mk, mo = sum(ks) / m, sum(os_) / m
    var = sum((k - mk) ** 2 for k in ks)
    slope = sum((k - mk) * (o - mo) for k, o in zip(ks, os_)) / var if var > 0 else 0.0
    icpt = mo - slope * mk
    span = max(duration, ks[-1])
    if abs(slope) * span < 2.5:
        med = sorted(os_)[m // 2]
        return (lambda t: med), f"constant {med:+.2f}s ({m}/{n} ankers)", m
    return (lambda t: icpt + slope * t), f"drift {slope * 3600:+.2f}s/uur, start {icpt:+.2f}s ({m}/{n} ankers)", m


async def _ref_sync(
    input_value: str, cues: list[list], is_tv: bool, duration: float, ref_sub_idx: int
) -> tuple[list[list], int, int] | None:
    """Sync tegen de ingebakken ondertitel van het bestand zelf: ~11 vensters verspreid over
    de film, per venster een paar kandidaat-pieken van de onset-correlatie, daarna het meest
    vloeiende pad door die kandidaten (_pick_offset_path), licht gladgestreken en lineair
    geïnterpoleerd. Volgt zowel constante offsets als drift of een andere montage."""
    win = 240.0 if is_tv else 300.0
    d = duration if duration > 0 else (2700.0 if is_tv else 6600.0)
    fracs = [0.03, 0.12, 0.21, 0.30, 0.39, 0.48, 0.57, 0.66, 0.75, 0.84, 0.93]
    starts = _pick_window_starts(duration, is_tv, win, fracs)
    sem = asyncio.Semaphore(3)

    async def one(t0: float):
        async with sem:
            ref = await _extract_sub_window(input_value, t0, win, ref_sub_idx)
            if ref is None:
                return t0, []
            return t0, _ref_offset_candidates(ref, cues, t0, win, 0.0, 120.0)

    results = sorted(await asyncio.gather(*[one(t) for t in starts]))
    # 'sub-tijd' van een venster ~ midden van het venster min de offset; voor DP volstaat
    # de venstermidden (offsets verschillen slechts seconden t.o.v. vensters van minuten).
    windows = [(t0 + win / 2, cands) for t0, cands in results]
    n_valid = sum(1 for _, c in windows if c)
    path = _pick_offset_path(windows)
    if n_valid < 3 or len(path) < 3:
        return None
    # lichte gladstrijking (mediaan van 3) tegen eenzame foute vensters
    offs = [o for _, o in path]
    smooth = [offs[0]] + [sorted(offs[i - 1:i + 2])[1] for i in range(1, len(offs) - 1)] + [offs[-1]]
    anchors = [(t - o, o_s) for (t, _), o, o_s in zip(path, offs, smooth)]  # (ondertitel-tijd, offset)
    anchors.sort()
    print("sync ref-pad (sub-tijd s, offset s): " + ", ".join(f"({k:.0f}, {o:+.1f})" for k, o in anchors))

    ks = [a[0] for a in anchors]
    os_ = [a[1] for a in anchors]

    def offset_at(t: float) -> float:
        if t <= ks[0]:
            return os_[0]
        if t >= ks[-1]:
            return os_[-1]
        for i in range(len(ks) - 1):
            if ks[i] <= t <= ks[i + 1]:
                span = ks[i + 1] - ks[i]
                return os_[i] + (os_[i + 1] - os_[i]) * ((t - ks[i]) / span if span > 0 else 0.0)
        return os_[-1]

    jumps = sum(1 for i in range(len(os_) - 1) if abs(os_[i + 1] - os_[i]) > 4.0)
    shifted = []
    for st_, en, tx in cues:
        o = offset_at(st_)
        shifted.append([max(0.0, st_ + o), max(0.0, en + o), tx])
    return shifted, n_valid, jumps


def _fit_offset_model(anchors: list[tuple[float, float]], duration: float):
    """anchors = [(ondertitel-tijd, offset)] gesorteerd. Kiest het eenvoudigste model dat de
    metingen verklaart: constant, lineaire drift (andere framerate) of één montage-sprong.
    Onverklaarbare ruis -> constante mediaan (nooit tussen ruiswaarden heen en weer
    interpoleren). Geeft (functie, beschrijving)."""
    ks = [a[0] for a in anchors]
    os_ = [a[1] for a in anchors]
    med = sorted(os_)[len(os_) // 2]
    if max(os_) - min(os_) <= 2.0 or len(anchors) < 3:
        return (lambda t: med), f"constant {med:+.2f}s"

    # lineaire drift
    n = len(anchors)
    mk, mo = sum(ks) / n, sum(os_) / n
    var = sum((k - mk) ** 2 for k in ks)
    slope = sum((k - mk) * (o - mo) for k, o in zip(ks, os_)) / var if var > 0 else 0.0
    icpt = mo - slope * mk
    resid = max(abs(o - (icpt + slope * k)) for k, o in zip(ks, os_))
    if resid <= 1.5 and abs(slope) * max(duration, ks[-1]) >= 2.5:
        return (lambda t: icpt + slope * t), f"drift {slope * 3600:+.2f}s/uur (rest {resid:.2f}s)"

    # één sprong: twee plateaus met elk >= 2 ankers
    best = None
    for i in range(2, n - 1):
        left, right = os_[:i], os_[i:]
        if len(right) < 2 or max(left) - min(left) > 1.5 or max(right) - min(right) > 1.5:
            continue
        ml, mr = sorted(left)[len(left) // 2], sorted(right)[len(right) // 2]
        if abs(mr - ml) >= 2.5:
            best = (i, ml, mr)
            break
    if best:
        i, ml, mr = best
        boundary = (ks[i - 1] + ks[i]) / 2
        return (lambda t: ml if t < boundary else mr), f"sprong {ml:+.2f}s -> {mr:+.2f}s bij {boundary:.0f}s"

    return (lambda t: med), f"ruis -> constant {med:+.2f}s (spreiding {max(os_) - min(os_):.1f}s)"


async def _multiwindow_sync(
    input_value: str, cues: list[list], is_tv: bool, duration: float, audio_idx: int | None,
    ref_sub_idx: int | None = None,
) -> tuple[list[list], int, int] | None:
    """Twee stappen. 1) Grof: een paar brede vensters (+-100s) geven de globale offset (de
    ondertitel hoort vaak bij een andere montage, bv. 60s extra studio-logo's). 2) Fijn:
    meer vensters verspreid over de film, elk met een smal zoekbereik (+-18s) rond die
    schatting, daarna het eenvoudigste model dat de metingen verklaart (zie
    _fit_offset_model). Eén globale offset (ffsubsync standaard) mist drift en
    montage-sprongen; blind breed zoeken per venster geeft vals-positieven.
    Geeft (nieuwe cues, aantal geldige ankers, aantal sprongen) of None."""
    if ref_sub_idx is not None:
        ref_result = await _ref_sync(input_value, cues, is_tv, duration, ref_sub_idx)
        if ref_result is not None:
            return ref_result
        print("sync: referentie-ondertitel gaf geen consistent resultaat - terugval op audio")
        ref_sub_idx = None
    sem = asyncio.Semaphore(3)

    async def measure(t0, win, center=0.0, pad=_SYNC_WINDOW_PAD, max_off=_SYNC_MAX_OFFSET):
        if ref_sub_idx is not None:
            # Beste meetmethode: vergelijk met de ingebakken ondertitel van dit bestand.
            ref = await _extract_sub_window(input_value, t0, win, ref_sub_idx)
            if ref is not None:
                return _ref_offset(ref, cues, t0, win, center, max_off if center else 120.0)
        return await _window_offset(input_value, cues, t0, win, audio_idx, center=center, pad=pad, max_off=max_off)

    async def run(starts, win, **kw):
        async def one(t0):
            async with sem:
                return t0, await measure(t0, win, **kw)
        return await asyncio.gather(*[one(t) for t in starts])

    # --- stap 1: grove schatting ---
    win1 = (180.0 if ref_sub_idx is not None else 300.0) if not is_tv else 240.0
    coarse = [(t0, o) for t0, o in await run(
        _pick_window_starts(duration, is_tv, win1, [0.12, 0.45, 0.78]), win1) if o is not None]
    if not coarse:
        return None
    offs = sorted(o for _, o in coarse)
    center = offs[len(offs) // 2]
    agree = [o for o in offs if abs(o - center) <= 15.0]
    print(f"sync grof: {[round(o, 1) for o in offs]} -> centrum {center:+.1f}s ({len(agree)}/{len(offs)} akkoord)")
    if len(offs) >= 2 and len(agree) < 2:
        return None  # geen onderling consistente schatting: liever niets dan gokken
    center = sorted(agree)[len(agree) // 2]

    # --- stap 2: fijn, smal bereik rond het centrum ---
    win2 = 150.0 if ref_sub_idx is not None else 180.0
    fine_fracs = [0.06, 0.20, 0.34, 0.48, 0.62, 0.76, 0.90]
    fine = await run(_pick_window_starts(duration, is_tv, win2, fine_fracs), win2,
                     center=center, pad=0.0, max_off=18.0)
    anchors = sorted((t0 + win2 / 2 - off, off) for t0, off in fine if off is not None)
    print("sync fijn (sub-tijd s, offset s): " + ", ".join(f"({k:.0f}, {o:+.2f})" for k, o in anchors))
    if len(anchors) < 2:
        const = center
        offset_at = lambda t: const
        desc, n_anchors, jumps = f"alleen grof centrum {center:+.2f}s", len(agree), 0
    else:
        offset_at, desc = _fit_offset_model(anchors, duration)
        n_anchors = len(anchors)
        jumps = 1 if desc.startswith("sprong") else 0
    print(f"sync model: {desc}")

    shifted = []
    for st, en, tx in cues:
        o = offset_at(st)
        shifted.append([max(0.0, st + o), max(0.0, en + o), tx])
    return shifted, n_anchors, jumps


def _release_name_from_url(decoded_url: str) -> str:
    """Bestandsnaam uit de (al gedecodeerde) stream-URL. Verschillende
    releases van dezelfde episode/film kunnen een andere montage hebben
    (recap wel/niet, andere intro-lengte, ...), dus de sync-offset die voor
    de ene release berekend is, is niet per se geldig voor een andere."""
    try:
        path = urllib.parse.urlparse(decoded_url).path
        return path.rsplit("/", 1)[-1] or decoded_url
    except Exception:
        return decoded_url


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

    input_value = urllib.parse.unquote(url)
    release = _release_name_from_url(input_value)
    release_hash = hashlib.sha256(release.encode("utf-8")).hexdigest()[:12]
    cache_key = f"{_SUB_CACHE_VERSION}:{tmdb_id}:{media_type}:{season}:{episode}:{lang}:{release_hash}"
    cached = _subtitle_cache_get(cache_key)
    if cached:
        return Response(content=cached, media_type="text/vtt", headers={"Cache-Control": "no-cache"})

    if _os_quota_active():
        reset_str = datetime.fromtimestamp(_OS_QUOTA_RESET_AT, tz=timezone.utc).strftime("%H:%M UTC")
        raise HTTPException(
            status_code=503,
            detail=f"Dagelijkse OpenSubtitles-limiet bereikt, probeer opnieuw na {reset_str}.",
        )

    http_src = _is_http_url(input_value)
    moviehash = await _osdb_hash(input_value) if http_src else None
    candidates = await _search_opensubtitles(
        tmdb_id, media_type, lang, season, episode, release=release, moviehash=moviehash
    )
    if not candidates:
        raise HTTPException(status_code=404, detail=f"Geen {lang}-ondertitels gevonden op OpenSubtitles.")

    is_tv = media_type == "tv"
    # Referentie-audio = het Engelse/Nederlandse spoor (zoals het afspelen zelf), niet
    # zomaar het eerste (kan een andere taalversie met andere montage zijn).
    probe = await _ffprobe_streams(input_value, is_path=False)
    audio = _default_audio_stream((probe or {}).get("streams") or [])
    audio_idx = int(audio["index"]) if audio and audio.get("index") is not None else None
    duration = await _ffprobe_duration_seconds(input_value, is_path=False) or 0.0
    ref_sub_idx = await _pick_reference_subtitle(input_value)
    print(f"[sync] moviehash={moviehash} duur={duration:.0f}s audio_idx={audio_idx} ref_sub={ref_sub_idx} kandidaten={len(candidates)}")

    fallback_cues = None   # eerste succesvolle download, voor als niets wil synchroniseren
    best = None            # (kwaliteit, cues)
    for cand in candidates:
        srt_text = await _download_opensubtitles(cand["file_id"])
        if not srt_text:
            continue
        cues = _srt_parse(srt_text)
        if len(cues) < 20:
            continue
        if fallback_cues is None or cand["moviehash_match"]:
            fallback_cues = cues
        result = await _multiwindow_sync(input_value, cues, is_tv, duration, audio_idx, ref_sub_idx)
        if result is None:
            if cand["moviehash_match"]:
                best = (10_000, cues)   # bit-exact zelfde bestand: ook zonder meting betrouwbaar
                break
            continue
        synced, n_anchors, jumps = result
        quality = n_anchors * 10 - jumps * 15 + (1000 if cand["moviehash_match"] else 0)
        print(f"[sync] kandidaat '{cand['release'][:60]}' ankers={n_anchors} sprongen={jumps} kwaliteit={quality}")
        if best is None or quality > best[0]:
            best = (quality, synced)
        # Voldoende bewijs dat het klopt over de héle film: niet nog meer downloads verbranden.
        if n_anchors >= 5:
            break

    final = best[1] if best else fallback_cues
    if not final:
        raise HTTPException(status_code=502, detail="Kon ondertitel niet downloaden van OpenSubtitles.")
    vtt = _cues_to_vtt(final)
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
    a, audio_stream = _resolve_audio(streams, audio_stream)
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
    # Onbekende hoogte (ffprobe gaf niks terug, bv. door timeout op een grote
    # 4K/HDR/DV-bron over een trage debrid-link) moet voorzichtig behandeld worden
    # als "kan 4K zijn" i.p.v. "geen schaling nodig" - anders probeert ultrafast
    # x264 een onbekende, mogelijk 4K-bron realtime te encoderen zonder de
    # 1080p-veiligheidscap, wat de CPU niet bijhoudt (hapering).
    do_scale = bool(max_h and max_h > 0) and (not v_height or v_height > max_h)

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
