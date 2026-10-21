"""Read-only parser for metadata chunks in WAV/BWF/RF64/BW64 and AIFF files.

Only chunk headers and metadata chunks are read; the audio data is skipped.
"""

from __future__ import annotations

import io
import re
import struct
import xml.etree.ElementTree as ET
from pathlib import Path

MAX_META_CHUNK = 16 * 1024 * 1024  # skip absurdly large non-audio chunks

PRINTABLE_RUN = re.compile(rb"[\x20-\x7e\t]{4,}")


def _text(b: bytes) -> str:
    b = b.split(b"\x00", 1)[0] if b"\x00" in b else b
    for enc in ("utf-8", "cp1252", "latin-1"):
        try:
            return b.decode(enc).strip()
        except UnicodeDecodeError:
            continue
    return b.decode("latin-1", errors="replace").strip()


def _printable_preview(b: bytes, limit: int = 240) -> str:
    runs = [r.decode("ascii", errors="replace") for r in PRINTABLE_RUN.findall(b[:65536])]
    s = " | ".join(r.strip() for r in runs if r.strip())
    return s[:limit]


# ---------------------------------------------------------------- decoders

def decode_bext(b: bytes) -> dict:
    if len(b) < 602:
        b = b.ljust(602, b"\x00")
    (desc, orig, orig_ref, date, time_, tr_low, tr_high, version, umid,
     lv, lr, mtp, mml, msl) = struct.unpack_from("<256s32s32s10s8sIIH64shhhhh", b, 0)
    out = {
        "Description": _text(desc),
        "Originator": _text(orig),
        "OriginatorReference": _text(orig_ref),
        "OriginationDate": _text(date),
        "OriginationTime": _text(time_),
        "TimeReference": (tr_high << 32) | tr_low,
        "Version": version,
        "CodingHistory": _text(b[602:]),
    }
    if version >= 2:
        for k, v in (("LoudnessValue", lv), ("LoudnessRange", lr), ("MaxTruePeakLevel", mtp),
                     ("MaxMomentaryLoudness", mml), ("MaxShortTermLoudness", msl)):
            if v != 0x7FFF:
                out[k] = v / 100.0
    return {k: v for k, v in out.items() if v not in ("", None)}


def flatten_xml(b: bytes) -> dict:
    """{'BWFXML/USER/DESCRIPTION': 'text', ...}. Repeated paths are joined with ' | '."""
    b = b.rstrip(b"\x00").strip()
    if not b:
        return {}
    try:
        root = ET.fromstring(b)
    except ET.ParseError:
        # Some writers prepend junk or use a bad encoding declaration.
        start = b.find(b"<")
        try:
            root = ET.fromstring(b[start:].decode("utf-8", errors="replace"))
        except Exception:  # noqa: BLE001
            return {"_unparseable_xml": _printable_preview(b)}
    out: dict[str, str] = {}

    def strip_ns(tag: str) -> str:
        return tag.split("}", 1)[1] if "}" in tag else tag

    def walk(el, path):
        tag = strip_ns(el.tag)
        p = f"{path}/{tag}" if path else tag
        children = list(el)
        text = (el.text or "").strip()
        if not children and text:
            out[p] = f"{out[p]} | {text}" if p in out else text
        for attr, val in el.attrib.items():
            if val.strip():
                out[f"{p}@{strip_ns(attr)}"] = val.strip()
        for c in children:
            walk(c, p)

    walk(root, "")
    return out


INFO_NAMES = {
    "INAM": "Title", "IART": "Artist", "ICMT": "Comment", "ICOP": "Copyright",
    "ICRD": "DateCreated", "IGNR": "Genre", "IKEY": "Keywords", "IPRD": "Product",
    "ISBJ": "Subject", "ISFT": "Software", "ISRC": "Source", "ITRK": "Track",
    "IENG": "Engineer", "ITCH": "Technician", "ICMS": "Commissioned", "ISRF": "SourceForm",
}


def decode_list_info(b: bytes) -> dict:
    out = {}
    pos = 4  # after 'INFO'
    while pos + 8 <= len(b):
        cid = b[pos:pos + 4].decode("latin-1")
        size = struct.unpack_from("<I", b, pos + 4)[0]
        val = _text(b[pos + 8: pos + 8 + size])
        if val:
            out[INFO_NAMES.get(cid, cid)] = val
        pos += 8 + size + (size & 1)
    return out


def decode_id3(b: bytes) -> dict:
    try:
        from mutagen.id3 import ID3

        tags = ID3(io.BytesIO(b))
    except Exception:  # noqa: BLE001
        return {"_unparseable_id3": _printable_preview(b)}
    out = {}
    for key, frame in tags.items():
        try:
            text = "; ".join(str(t) for t in frame.text) if hasattr(frame, "text") else str(frame)
        except Exception:  # noqa: BLE001
            continue
        if text.strip():
            out[key] = text.strip()
    return out


def decode_smpl(b: bytes) -> dict:
    if len(b) < 36:
        return {}
    (_mfr, _prod, period, unity, _fract, _smpte_fmt, _smpte_off, n_loops, _extra) = struct.unpack_from("<9I", b, 0)
    loops = []
    for i in range(min(n_loops, 32)):
        off = 36 + i * 24
        if off + 24 > len(b):
            break
        _cue, ltype, start, end, _frac, count = struct.unpack_from("<6I", b, off)
        loops.append({"start": start, "end": end, "type": ltype, "count": count})
    return {"MIDIUnityNote": unity, "Loops": loops, "LoopCount": n_loops}


def decode_acid(b: bytes) -> dict:
    if len(b) < 24:
        return {}
    flags, root, _u1, _u2, beats, meter_den, meter_num, tempo = struct.unpack_from("<IHHfIHHf", b, 0)
    return {
        "OneShot": bool(flags & 0x01),
        "RootNoteSet": bool(flags & 0x02),
        "RootNote": root,
        "Beats": beats,
        "Meter": f"{meter_num}/{meter_den}",
        "Tempo": round(tempo, 3),
    }


def decode_fmt(b: bytes) -> dict:
    if len(b) < 16:
        return {}
    tag, ch, sr, _bps, align, bits = struct.unpack_from("<HHIIHH", b, 0)
    out = {"FormatTag": tag, "Channels": ch, "SampleRate": sr, "BlockAlign": align, "BitsPerSample": bits}
    if tag == 0xFFFE and len(b) >= 40:
        out["ValidBits"] = struct.unpack_from("<H", b, 18)[0]
        out["ChannelMask"] = struct.unpack_from("<I", b, 20)[0]
    return out


# ---------------------------------------------------------------- containers

def read_wav_chunks(path: Path) -> dict:
    """Returns {'container', 'chunks': [{id,size}], 'fields': {group: {...}},
    'technical': {...}, 'warnings': [...]}"""
    result = {"container": None, "chunks": [], "fields": {}, "technical": {}, "warnings": []}
    with open(path, "rb") as f:
        f.seek(0, 2)
        file_size = f.tell()
        f.seek(0)
        hdr = f.read(12)
        if len(hdr) < 12 or hdr[8:12] not in (b"WAVE",):
            result["warnings"].append("not a RIFF/WAVE file")
            return result
        container = hdr[0:4].decode("latin-1")
        result["container"] = container
        ds64 = {}
        data_size = None
        pos = 12
        while pos + 8 <= file_size:
            f.seek(pos)
            h = f.read(8)
            if len(h) < 8:
                break
            cid = h[0:4].decode("latin-1", errors="replace")
            size = struct.unpack("<I", h[4:8])[0]
            if cid == "data" and size == 0xFFFFFFFF and "dataSize" in ds64:
                size = ds64["dataSize"]
            elif size == 0xFFFFFFFF and cid in ds64.get("table", {}):
                size = ds64["table"][cid]
            if pos + 8 + size > file_size:
                result["warnings"].append(f"chunk '{cid}' claims {size} bytes but the file ends early")
                size = max(0, file_size - pos - 8)
            result["chunks"].append({"id": cid, "size": size})
            if cid == "data":
                data_size = size
            elif size <= MAX_META_CHUNK:
                body = f.read(size)
                _store_wav_chunk(result, cid, body, ds64)
            else:
                result["warnings"].append(f"skipped very large '{cid}' chunk ({size} bytes)")
            pos += 8 + size + (size & 1)
        fmt = result["fields"].get("fmt", {})
        if data_size and fmt.get("BlockAlign") and fmt.get("SampleRate"):
            frames = data_size // fmt["BlockAlign"]
            result["technical"] = {
                "SampleRate": fmt["SampleRate"],
                "Channels": fmt["Channels"],
                "BitsPerSample": fmt["BitsPerSample"],
                "Duration": frames / fmt["SampleRate"],
            }
    return result


def _store_wav_chunk(result: dict, cid: str, body: bytes, ds64: dict) -> None:
    fields = result["fields"]
    try:
        if cid == "ds64" and len(body) >= 28:
            riff_size, data_size, _samples, table_len = struct.unpack_from("<QQQI", body, 0)
            ds64["dataSize"] = data_size
            ds64["table"] = {}
            for i in range(table_len):
                off = 28 + i * 12
                if off + 12 <= len(body):
                    tid = body[off:off + 4].decode("latin-1")
                    ds64["table"][tid] = struct.unpack_from("<Q", body, off + 4)[0]
        elif cid == "fmt ":
            fields["fmt"] = decode_fmt(body)
        elif cid == "bext":
            fields["bext"] = decode_bext(body)
        elif cid in ("iXML", "IXML"):
            fields["iXML"] = flatten_xml(body)
        elif cid in ("_PMX", "XMP "):
            fields["XMP"] = flatten_xml(body)
        elif cid == "LIST" and body[:4] == b"INFO":
            fields.setdefault("INFO", {}).update(decode_list_info(body))
        elif cid == "LIST":
            fields.setdefault("LIST", {})[body[:4].decode("latin-1")] = f"{len(body)} bytes"
        elif cid in ("id3 ", "ID3 "):
            fields["ID3"] = decode_id3(body)
        elif cid == "smpl":
            fields["smpl"] = decode_smpl(body)
        elif cid == "acid":
            fields["acid"] = decode_acid(body)
        elif cid == "cue ":
            fields["cue"] = {"CuePoints": struct.unpack_from("<I", body, 0)[0] if len(body) >= 4 else 0}
        elif cid in ("fact", "PAD ", "JUNK", "junk", "FLLR", "pad ", "elm1", "minf", "regn", "umid"):
            pass
        else:
            preview = _printable_preview(body)
            fields.setdefault("other_chunks", {})[cid.strip() or repr(cid)] = preview or f"{len(body)} bytes (binary)"
    except Exception as e:  # noqa: BLE001
        result["warnings"].append(f"could not decode '{cid}': {e}")


def _ieee_extended(b: bytes) -> float:
    exp, mant = struct.unpack(">HQ", b)
    sign = -1 if exp & 0x8000 else 1
    exp &= 0x7FFF
    if exp == 0 and mant == 0:
        return 0.0
    return sign * mant * 2.0 ** (exp - 16383 - 63)


AIFF_TEXT = {"NAME": "Title", "AUTH": "Author", "(c) ": "Copyright", "ANNO": "Annotation"}


def read_aiff_chunks(path: Path) -> dict:
    result = {"container": None, "chunks": [], "fields": {}, "technical": {}, "warnings": []}
    with open(path, "rb") as f:
        f.seek(0, 2)
        file_size = f.tell()
        f.seek(0)
        hdr = f.read(12)
        if hdr[0:4] != b"FORM" or hdr[8:12] not in (b"AIFF", b"AIFC"):
            result["warnings"].append("not an AIFF file")
            return result
        result["container"] = hdr[8:12].decode()
        pos = 12
        while pos + 8 <= file_size:
            f.seek(pos)
            h = f.read(8)
            cid = h[0:4].decode("latin-1", errors="replace")
            size = struct.unpack(">I", h[4:8])[0]
            size = min(size, max(0, file_size - pos - 8))
            result["chunks"].append({"id": cid, "size": size})
            if cid != "SSND" and size <= MAX_META_CHUNK:
                body = f.read(size)
                try:
                    if cid == "COMM" and len(body) >= 18:
                        ch, frames, bits = struct.unpack(">hIh", body[:8])
                        sr = _ieee_extended(body[8:18])
                        result["technical"] = {"SampleRate": sr, "Channels": ch, "BitsPerSample": bits,
                                               "Duration": frames / sr if sr else None}
                    elif cid in AIFF_TEXT:
                        result["fields"].setdefault("AIFF", {})[AIFF_TEXT[cid]] = _text(body)
                    elif cid in ("ID3 ", "id3 "):
                        result["fields"]["ID3"] = decode_id3(body)
                    elif cid == "COMT":
                        result["fields"].setdefault("AIFF", {})["Comments"] = _printable_preview(body, 1000)
                    elif cid in ("iXML", "IXML"):
                        result["fields"]["iXML"] = flatten_xml(body)
                    elif cid not in ("FVER", "MARK", "INST", "APPL"):
                        result["fields"].setdefault("other_chunks", {})[cid] = _printable_preview(body)
                except Exception as e:  # noqa: BLE001
                    result["warnings"].append(f"could not decode '{cid}': {e}")
            pos += 8 + size + (size & 1)
    return result


def read_tags_generic(path: Path) -> dict:
    """Tags for MP3/FLAC/M4A/OGG via mutagen."""
    result = {"container": None, "chunks": [], "fields": {}, "technical": {}, "warnings": []}
    try:
        import mutagen

        m = mutagen.File(str(path))
    except Exception as e:  # noqa: BLE001
        result["warnings"].append(f"mutagen: {e}")
        return result
    if m is None:
        result["warnings"].append("unrecognised format")
        return result
    result["container"] = type(m).__name__
    if m.info is not None:
        result["technical"] = {
            "SampleRate": getattr(m.info, "sample_rate", None),
            "Channels": getattr(m.info, "channels", None),
            "BitsPerSample": getattr(m.info, "bits_per_sample", None),
            "Duration": getattr(m.info, "length", None),
        }
    tags = {}
    if m.tags is not None:
        for key, value in m.tags.items():
            try:
                if hasattr(value, "text"):
                    text = "; ".join(str(t) for t in value.text)
                elif isinstance(value, list):
                    text = "; ".join(
                        v.decode("utf-8", errors="replace") if isinstance(v, (bytes, bytearray)) else str(v)
                        for v in value
                    )
                else:
                    text = str(value)
            except Exception:  # noqa: BLE001
                continue
            if text.strip() and len(text) < 5000:
                tags[str(key)] = text.strip()
    result["fields"]["tags"] = tags
    return result


def read_file_metadata(path: Path) -> dict:
    ext = Path(path).suffix.lower()
    try:
        if ext in (".wav", ".wave", ".bwf", ".rf64"):
            with open(path, "rb") as f:
                magic = f.read(4)
            if magic in (b"RIFF", b"RF64", b"BW64"):
                return read_wav_chunks(path)
        if ext in (".aif", ".aiff", ".aifc"):
            return read_aiff_chunks(path)
        return read_tags_generic(path)
    except Exception as e:  # noqa: BLE001
        return {"container": None, "chunks": [], "fields": {}, "technical": {}, "warnings": [f"failed: {e}"]}
