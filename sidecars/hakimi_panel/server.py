#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Antigravity Native Sidecar Server for Gemini Hakimi Token & Rate-Limit Widget
(反重力哈基米记账内置 Sidecar 面板服务)
"""

import os
import re
import ssl
import sys
import threading
import urllib.request
import json
import time
import glob
import ctypes
import signal
import sqlite3
import urllib.parse
import subprocess
from datetime import datetime, timezone, timedelta
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

SIDE_DIR = os.path.dirname(os.path.abspath(__file__))
PLUGIN_DIR = os.path.abspath(os.path.join(SIDE_DIR, "..", ".."))
ASSETS_DIR = os.path.join(PLUGIN_DIR, "assets")
CONFIG_PATH = os.path.join(PLUGIN_DIR, "config", "config.json")
PID_FILE = os.path.join(PLUGIN_DIR, "config", "pet.pid")
PRICING_PATH = os.path.join(PLUGIN_DIR, "src", "Pricing.json")
QUOTES_PATH = os.path.join(ASSETS_DIR, "quotes.json")
WIDGET_PS1 = os.path.join(PLUGIN_DIR, "src", "HakimiWidget.ps1")

AGY_DIR = os.environ.get("ANTIGRAVITY_APP_DATA_DIR") or os.path.expanduser(r"~\.gemini\antigravity")
BRAIN_DIR = os.path.join(AGY_DIR, "brain")
DB_SUMMARIES = os.path.join(AGY_DIR, "conversation_summaries.db")
PRELOAD_JS_SDK = os.path.join(AGY_DIR, "lib", "node_modules", "sidecar_sdk", "preload.js")

TRANSCRIPT_CACHE = {}
DESKTOP_PET_PROC = None


def load_json(path, default):
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                return json.load(f)
        except Exception:
            pass
    return default


def save_json(path, data):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


def get_config():
    default_cfg = {
        "position_x": None,
        "position_y": None,
        "scale": 1.0,
        "opacity": 1.0,
        "sound_enabled": True,
        "sound_volume": 0.8,
        "cache_sound_enabled": False,
        "speech_bubble_enabled": True,
        "topmost": True,
        "click_through": False,
        "follow_antigravity": True,
        "hide_with_antigravity": True,
        "auto_launch_desktop_pet": False,
        "active_model": "gemini-4-hydrogen",
        "active_plan": "free",
        "antigravity_brain_path": BRAIN_DIR
    }
    cfg = load_json(CONFIG_PATH, default_cfg)
    for k, v in default_cfg.items():
        if k not in cfg:
            cfg[k] = v
    return cfg



CONV_MODEL_CACHE = {}
_LAST_PBTXT_MODEL = None
_LAST_STEP_MODEL_SIG = None

_MODEL_MATCH_RULES = (
    ("gemini-4-hydrogen", ("MODEL_PLACEHOLDER_M525", "MODEL_PLACEHOLDER_M526", "MODEL_PLACEHOLDER_M527", "MODEL_PLACEHOLDER_M528", "MODEL_PLACEHOLDER_M669", "gemini-flash-worker-agy", "gemini-flash-worker", "flash-worker", "gemini-4-hydrogen", "hydrogen")),
    ("gemini-4-carbon", ("MODEL_PLACEHOLDER_M670", "gemini-4-carbon", "carbon")),
    ("gemini-4-argon", ("MODEL_PLACEHOLDER_M417", "MODEL_PLACEHOLDER_M418", "MODEL_PLACEHOLDER_M419", "MODEL_PLACEHOLDER_M668", "gemini-pro-orchestrator-g1-pro", "gemini-pro-orchestrator", "orchestrator", "gemini-4-argon", "argon")),
    ("claude-opus-5-5", ("MODEL_PLACEHOLDER_M400", "MODEL_PLACEHOLDER_M401", "MODEL_PLACEHOLDER_M402", "MODEL_PLACEHOLDER_M26", "claude-opus", "opus")),
    ("claude-sonnet-5-5", ("MODEL_PLACEHOLDER_M403", "MODEL_PLACEHOLDER_M404", "MODEL_PLACEHOLDER_M405", "claude-sonnet", "sonnet")),
    ("gemini-3.8-flash", ("MODEL_PLACEHOLDER_M318", "MODEL_PLACEHOLDER_M319", "MODEL_PLACEHOLDER_M320", "MODEL_PLACEHOLDER_M322", "gemini-3.8-flash-tiered", "gemini-3.8-flash-n", "gemini-3.8-flash", "flash")),
)

_INVOKED_MODEL_ID_RE = re.compile(r"((?:gemini|claude|gpt)-[a-z0-9.\-]+)", re.I)
_MODEL_ENUM_RE = re.compile(r"model_enum[^\w]*(MODEL_[A-Z0-9_]+)")
_LAST_STEP_IDX_RE = re.compile(r"last_step_index[^\d]*(\d+)")
_RAW_PAIR_RE = re.compile(
    r"((?:gemini|claude|gpt)-[a-z0-9.\-]+)[\s\S]{1,260}?model_enum[^\w]*(MODEL_[A-Z0-9_]+)|model_enum[^\w]*(MODEL_[A-Z0-9_]+)",
    re.I,
)


def map_raw_model_key(raw_text, placeholder=""):
    """Map placeholder tokens, model IDs, or labels to canonical pricing model keys."""
    combined = f"{raw_text} {placeholder}".lower()
    for mkey, tokens in _MODEL_MATCH_RULES:
        for tok in tokens:
            if tok.lower() in combined:
                return mkey
    return None


def _decode_packed_step_indices(blob):
    """Decode protobuf field 2 (wire type 2) packed varint step indices from gen_metadata.data."""
    if not blob or blob[0] != 0x12:
        return []
    pos = 1
    length = 0
    shift = 0
    while pos < len(blob):
        b = blob[pos]
        pos += 1
        length |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    end = min(len(blob), pos + length)
    indices = []
    while pos < end:
        val = 0
        shift = 0
        while pos < end:
            b = blob[pos]
            pos += 1
            val |= (b & 0x7F) << shift
            if not (b & 0x80):
                break
            shift += 7
        indices.append(val)
    return indices


def _fallback_read_tail_model(db_path):
    """Read raw tail bytes of conversation DB when sqlite3 read-only query fails."""
    try:
        st_size = os.path.getsize(db_path)
        with open(db_path, "rb") as f:
            f.seek(max(0, st_size - 262144))
            tail = f.read().decode("latin-1", errors="ignore")
        matches = list(_RAW_PAIR_RE.finditer(tail))
        for m in reversed(matches):
            raw_id = (m.group(1) or "").lower()
            enum_str = m.group(2) or m.group(3) or ""
            mkey = map_raw_model_key(raw_id, enum_str)
            if mkey:
                return mkey, (raw_id or enum_str or mkey), enum_str
    except Exception:
        pass
    return None, "", ""


def get_conv_step_models(conv_id, fallback_model=None):
    """Extract per-step actual invoked model IDs from conversations/<conv_id>.db with incremental caching."""
    if fallback_model is None:
        fallback_model = detect_antigravity_active_model()
    empty_res = {
        "mtime": 0.0,
        "size": 0,
        "last_idx": -1,
        "step_map": {},
        "latest_model": fallback_model,
        "latest_invoked_id": fallback_model,
        "latest_enum": "",
    }
    if not conv_id:
        return empty_res

    db_path = os.path.join(AGY_DIR, "conversations", f"{conv_id}.db")
    if not os.path.exists(db_path):
        return empty_res

    try:
        st = os.stat(db_path)
    except OSError:
        return empty_res

    cached = CONV_MODEL_CACHE.get(conv_id)
    if cached and cached.get("mtime") == st.st_mtime and cached.get("size") == st.st_size:
        return cached

    if cached:
        step_map = dict(cached.get("step_map", {}))
        last_idx = int(cached.get("last_idx", -1))
        latest_model = cached.get("latest_model") or fallback_model
        latest_invoked_id = cached.get("latest_invoked_id") or latest_model
        latest_enum = cached.get("latest_enum") or ""
    else:
        step_map = {}
        last_idx = -1
        latest_model = fallback_model
        latest_invoked_id = fallback_model
        latest_enum = ""

    sqlite_ok = False
    try:
        uri_path = urllib.request.pathname2url(os.path.abspath(db_path))
        conn = sqlite3.connect(f"file:{uri_path}?mode=ro", uri=True, timeout=1.0)
        cur = conn.cursor()
        rows = cur.execute(
            "SELECT idx, substr(data, 1, 64), substr(data, -700) FROM gen_metadata WHERE idx > ? ORDER BY idx ASC",
            (last_idx,),
        ).fetchall()
        conn.close()
        sqlite_ok = True

        for row_idx, head_bytes, tail_bytes in rows:
            if row_idx > last_idx:
                last_idx = int(row_idx)
            tail = (tail_bytes or b"").decode("latin-1", errors="ignore")
            m_ids = _INVOKED_MODEL_ID_RE.findall(tail)
            raw_id = m_ids[-1].lower() if m_ids else ""
            m_enum = _MODEL_ENUM_RE.search(tail)
            enum_str = m_enum.group(1) if m_enum else ""
            mkey = map_raw_model_key(raw_id, enum_str)
            if not mkey:
                continue
            invoked_id = raw_id or enum_str or mkey
            steps = _decode_packed_step_indices(head_bytes or b"")
            m_ls = _LAST_STEP_IDX_RE.search(tail)
            if steps:
                if m_ls:
                    ls_idx = int(m_ls.group(1))
                    max_s = max(steps)
                    if max_s > ls_idx and (max_s - ls_idx) <= 64:
                        cover_range = range(ls_idx + 1, max_s + 1)
                    else:
                        cover_range = steps
                else:
                    cover_range = steps
            elif m_ls:
                ls_idx = int(m_ls.group(1))
                cover_range = (ls_idx + 1, ls_idx + 2)
            else:
                cover_range = ()

            info_tuple = (mkey, invoked_id, enum_str)
            for s_idx in cover_range:
                step_map[int(s_idx)] = info_tuple
            latest_model = mkey
            latest_invoked_id = invoked_id
            latest_enum = enum_str
    except Exception:
        sqlite_ok = False

    if not sqlite_ok:
        fb_key, fb_invoked, fb_enum = _fallback_read_tail_model(db_path)
        if fb_key:
            latest_model = fb_key
            latest_invoked_id = fb_invoked
            latest_enum = fb_enum

    res = {
        "mtime": st.st_mtime,
        "size": st.st_size,
        "last_idx": last_idx,
        "step_map": step_map,
        "latest_model": latest_model,
        "latest_invoked_id": latest_invoked_id,
        "latest_enum": latest_enum,
    }
    CONV_MODEL_CACHE[conv_id] = res
    return res


def get_conv_model(conv_id):
    if not conv_id:
        return detect_antigravity_active_model()
    cm = get_conv_step_models(conv_id)
    return cm.get("latest_model") or detect_antigravity_active_model()


def detect_antigravity_active_model():
    pbtxt = os.path.join(AGY_DIR, "antigravity_state.pbtxt")
    if os.path.exists(pbtxt):
        try:
            with open(pbtxt, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
            m = re.search(r'last_selected_agent_model:\s*(\S+)', content)
            if m:
                val = m.group(1).strip('"\' ')
                mkey = map_raw_model_key(val)
                if mkey:
                    return mkey
        except Exception:
            pass
    return "gemini-4-hydrogen"


def get_pricing():
    default_pricing = {
        "usd_to_cny": 7.25,
        "default_model": "gemini-4-hydrogen",
        "context_window": 1048576,
        "models": {
            "gemini-4-hydrogen": {
                "display_name": "Gemini 4 Hydrogen",
                "short_name": "4 Hydrogen",
                "vendor": "Gemini",
                "badge": "NEW",
                "quota_pool": "flash_hydrogen",
                "pool_label": "Flash/H 共享池",
                "context_window": 1048576,
                "tiers": [{"hit": 0.075, "miss": 0.75, "out": 3.75}]
            },
            "gemini-3.8-flash": {
                "display_name": "Gemini 3.8 Flash",
                "short_name": "3.8 Flash",
                "vendor": "Gemini",
                "badge": "FLASH",
                "quota_pool": "flash_hydrogen",
                "pool_label": "Flash/H 共享池",
                "context_window": 1048576,
                "tiers": [{"hit": 0.075, "miss": 0.75, "out": 3.75}]
            },
            "gemini-4-argon": {
                "display_name": "Gemini 4 Argon",
                "short_name": "4 Argon",
                "vendor": "Gemini",
                "badge": "FLAGSHIP",
                "quota_pool": "argon",
                "pool_label": "Argon 独立池",
                "context_window": 1048576,
                "tiers": [{"hit": 0.1, "miss": 2.0, "out": 10.0}]
            },
            "claude-opus-5-5": {
                "display_name": "Claude Opus 5.5",
                "short_name": "Opus 5.5",
                "vendor": "Claude",
                "badge": "CLAUDE",
                "quota_pool": "claude",
                "pool_label": "Claude 独立池",
                "context_window": 200000,
                "tiers": [{"hit": 0.2, "miss": 4.0, "out": 20.0}]
            },
            "claude-sonnet-5-5": {
                "display_name": "Claude Sonnet 5.5",
                "short_name": "Sonnet 5.5",
                "vendor": "Claude",
                "badge": "CLAUDE",
                "quota_pool": "claude",
                "pool_label": "Claude 独立池",
                "context_window": 200000,
                "tiers": [{"hit": 0.1, "miss": 2.0, "out": 10.0}]
            },
            "gemini-4-carbon": {
                "display_name": "Gemini 4 Carbon",
                "short_name": "4 Carbon",
                "vendor": "Gemini",
                "badge": "ULTRA",
                "quota_pool": "carbon",
                "pool_label": "Carbon 独立池",
                "context_window": 1048576,
                "tiers": [{"hit": 0.15, "miss": 3.0, "out": 15.0}]
            }
        },
        "limits": {
            "free": {"rpm": 15, "tpm": 1000000, "rpd": 1500},
            "tier1": {"rpm": 1000, "tpm": 4000000, "rpd": 10000}
        }
    }
    return load_json(PRICING_PATH, default_pricing)


def calculate_cost(inp, cache, out, model_key, pricing):
    models = pricing.get("models", {})
    if model_key not in models:
        model_key = pricing.get("default_model", "gemini-2.5-flash")
    m = models.get(model_key, {})
    rate = float(pricing.get("usd_to_cny", 7.25))
    tiers = m.get("tiers", [{"hit": 0.075, "miss": 0.75, "out": 3.75}])

    total_in = inp + cache
    selected = tiers[0]
    for t in tiers:
        max_in = t.get("maxIn")
        if max_in is None or total_in <= max_in:
            selected = t
            break
        selected = t

    miss_price = float(selected.get("miss", 0.75))
    hit_price = float(selected.get("hit", 0.075))
    out_price = float(selected.get("out", 3.75))

    cost_usd = (inp / 1e6) * miss_price + (cache / 1e6) * hit_price + (out / 1e6) * out_price
    no_cache_usd = ((inp + cache) / 1e6) * miss_price + (out / 1e6) * out_price
    savings_usd = max(0.0, no_cache_usd - cost_usd)

    return {
        "cost_usd": round(cost_usd, 5),
        "cost_cny": round(cost_usd * rate, 4),
        "savings_usd": round(savings_usd, 5),
        "savings_cny": round(savings_usd * rate, 4),
        "raw_cost_usd": cost_usd,
        "raw_savings_usd": savings_usd,
    }


def parse_iso_ts(ts_str):
    if not ts_str:
        return 0.0
    try:
        s = ts_str.replace("Z", "+00:00")
        dt = datetime.fromisoformat(s)
        return dt.timestamp()
    except Exception:
        return 0.0


def parse_transcript_file(filepath):
    try:
        st = os.stat(filepath)
    except OSError:
        return None

    cached = TRANSCRIPT_CACHE.get(filepath)
    if cached and cached["mtime"] == st.st_mtime and cached["size"] == st.st_size:
        return cached

    parts = os.path.normpath(filepath).split(os.sep)
    conv_id = ""
    if "brain" in parts:
        idx = parts.index("brain")
        if idx + 1 < len(parts):
            conv_id = parts[idx + 1]

    steps = []
    last_user_query = ""
    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                if '"USER_INPUT"' in line or '"input_tokens"' in line:
                    try:
                        d = json.loads(line)
                    except Exception:
                        continue
                    if d.get("type") == "USER_INPUT":
                        c = (d.get("content") or "").strip()
                        if "<USER_REQUEST>" in c and "</USER_REQUEST>" in c:
                            c = c.split("<USER_REQUEST>", 1)[1].split("</USER_REQUEST>", 1)[0].strip()
                        if c:
                            last_user_query = c[:80]
                    elif d.get("input_tokens") is not None:
                        inp = int(d.get("input_tokens") or 0)
                        cache = int(d.get("cache_read_tokens") or 0)
                        out = int(d.get("output_tokens") or 0)
                        tot = inp + cache + out
                        hit_rate = round((cache / (inp + cache)) * 100, 1) if (inp + cache) > 0 else 0.0
                        created_at = d.get("created_at") or ""
                        ts = parse_iso_ts(created_at)
                        think_len = len(str(d.get("thinking") or ""))
                        steps.append({
                            "step_index": d.get("step_index", len(steps)),
                            "input_tokens": inp,
                            "cache_read_tokens": cache,
                            "output_tokens": out,
                            "total_tokens": tot,
                            "cache_hit_rate": hit_rate,
                            "created_at": created_at,
                            "ts": ts,
                            "thinking_len": think_len,
                            "query": last_user_query
                        })
    except Exception:
        pass

    entry = {
        "mtime": st.st_mtime,
        "size": st.st_size,
        "conv_id": conv_id,
        "steps": steps
    }
    TRANSCRIPT_CACHE[filepath] = entry
    return entry


def get_conversation_title(conv_id):
    if not conv_id or not os.path.exists(DB_SUMMARIES):
        return conv_id[:8] if conv_id else "当前会话"
    try:
        conn = sqlite3.connect(f"file:{DB_SUMMARIES}?mode=ro", uri=True, timeout=1.5)
        cur = conn.cursor()
        cur.execute("SELECT title FROM conversation_summaries WHERE conversation_id = ?", (conv_id,))
        row = cur.fetchone()
        conn.close()
        if row and row[0]:
            return row[0]
    except Exception:
        pass
    return conv_id[:8]


def _is_pid_alive(pid):
    if pid <= 0:
        return False
    try:
        SYNCHRONIZE = 0x00100000
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        h = ctypes.windll.kernel32.OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
        if not h:
            return False
        STILL_ACTIVE = 259
        exit_code = ctypes.c_ulong()
        ok = ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(exit_code))
        ctypes.windll.kernel32.CloseHandle(h)
        return bool(ok and exit_code.value == STILL_ACTIVE)
    except Exception:
        return False


def is_desktop_pet_running():
    global DESKTOP_PET_PROC
    if DESKTOP_PET_PROC is not None:
        if DESKTOP_PET_PROC.poll() is None:
            return True
        DESKTOP_PET_PROC = None
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE, "r", encoding="ascii", errors="ignore") as f:
                pid = int(f.read().strip())
            if _is_pid_alive(pid):
                return True
        except Exception:
            pass
    return False


_LS_CACHE = {"scheme": "", "port": 0, "csrf": "", "last_sync": 0.0, "quotas": {}, "plan_name": ""}
_SSL_UNVERIFIED = ssl._create_unverified_context()
_DIRECT_HTTP_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
_DIRECT_HTTPS_OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPSHandler(context=_SSL_UNVERIFIED),
)

_SHARED_POOL_PARTNERS = (
    ("gemini-4-hydrogen", "gemini-3.8-flash"),
    ("claude-opus-5-5", "claude-sonnet-5-5"),
)


def _format_countdown(secs_left):
    if secs_left <= 0:
        return "已就绪"
    total_mins = int(secs_left // 60)
    hours = total_mins // 60
    mins = total_mins % 60
    if hours >= 24:
        days = hours // 24
        rem_h = hours % 24
        return f"{days}d{rem_h}h"
    if hours > 0:
        return f"{hours}h{mins:02d}m"
    return f"{max(1, mins)}m"


def _probe_ls_get_user_status(port, csrf, preferred_scheme=""):
    schemes = [preferred_scheme] if preferred_scheme in ("https", "http") else []
    for s in ("https", "http"):
        if s not in schemes:
            schemes.append(s)
    for scheme in schemes:
        url = f"{scheme}://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/GetUserStatus"
        req = urllib.request.Request(
            url,
            data=b"{}",
            headers={
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
                "x-codeium-csrf-token": csrf,
            },
            method="POST",
        )
        try:
            opener = _DIRECT_HTTPS_OPENER if scheme == "https" else _DIRECT_HTTP_OPENER
            with opener.open(req, timeout=0.6) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            configs = data.get("userStatus", {}).get("cascadeModelConfigData", {}).get("clientModelConfigs", [])
            if configs:
                return data, scheme
        except Exception:
            continue
    return None, ""


def _discover_ls_candidates():
    found = []
    try:
        ps_cmd = (
            "Get-CimInstance Win32_Process -Filter \"Name LIKE 'language_server%'\" | ForEach-Object { "
            "$p = $_.ProcessId; $c = $_.CommandLine; "
            "if ($c -match '--csrf_token[=\\s]+([a-fA-F0-9\\-]+)') { "
            "$t = $Matches[1]; "
            "Get-NetTCPConnection -OwningProcess $p -State Listen -ErrorAction SilentlyContinue | Sort-Object LocalPort | ForEach-Object { "
            "Write-Output \"$p|$($_.LocalPort)|$t\" } } }"
        )
        out = subprocess.check_output(
            ["powershell.exe", "-NoProfile", "-Command", ps_cmd],
            timeout=2.5,
            creationflags=0x08000000,
        ).decode("utf-8", errors="ignore")
        for line in out.splitlines():
            parts = line.strip().split("|")
            if len(parts) == 3:
                try:
                    found.append((int(parts[0]), int(parts[1]), parts[2].strip()))
                except ValueError:
                    pass
    except Exception:
        pass
    return found


def _parse_model_quota_entry(cfg_item, now_utc):
    disabled = bool(cfg_item.get("disabled"))
    tag_title = str(cfg_item.get("tagTitle") or "")
    tag_desc = str(cfg_item.get("tagDescription") or "")
    qinfo = cfg_item.get("quotaInfo") or {}
    if disabled and not qinfo:
        return {
            "disabled": True,
            "is_weekly": False,
            "pct": 0,
            "window_label": tag_title or "Unavailable",
            "reset": "暂不可用 · 需 Ultra",
            "countdown": "--",
            "tag_desc": tag_desc,
        }

    frac = float(qinfo["remainingFraction"]) if "remainingFraction" in qinfo else (0.0 if "resetTime" in qinfo else 1.0)
    pct = max(0, min(100, int(round(frac * 100.0))))
    rtime = str(qinfo.get("resetTime") or "")
    is_weekly = False
    reset_str = "实时同步"
    countdown = ""
    if rtime:
        try:
            rdt = datetime.fromisoformat(rtime.replace("Z", "+00:00"))
            secs_left = (rdt - now_utc).total_seconds()
            hours_left = secs_left / 3600.0
            is_weekly = (hours_left > 24.0)
            local_dt = rdt.astimezone()
            countdown = _format_countdown(secs_left)
            if secs_left <= 0:
                reset_str = "已就绪 · 随时重置"
            elif is_weekly:
                reset_str = f"重置 {local_dt.strftime('%m-%d %H:%M')} ({countdown})"
            else:
                reset_str = f"重置 {local_dt.strftime('%H:%M:%S')} ({countdown})"
        except Exception:
            pass

    return {
        "disabled": disabled,
        "is_weekly": is_weekly,
        "pct": pct,
        "window_label": "多日周期池" if is_weekly else "5h 周期池",
        "reset": reset_str,
        "countdown": countdown,
        "tag_desc": tag_desc,
    }


def fetch_live_antigravity_quotas():
    now = time.time()
    if now - _LS_CACHE["last_sync"] < 3.0 and _LS_CACHE["quotas"]:
        return _LS_CACHE["quotas"]
    _LS_CACHE["last_sync"] = now

    bridge_path = os.path.join(PLUGIN_DIR, "config", "ls_bridge.json")
    initial_targets = []
    if _LS_CACHE["port"] > 0 and _LS_CACHE["csrf"]:
        initial_targets.append((0, _LS_CACHE["port"], _LS_CACHE["csrf"], _LS_CACHE["scheme"]))
    if os.path.exists(bridge_path):
        b = load_json(bridge_path, {})
        if b.get("port") and b.get("csrf"):
            b_item = (int(b.get("pid") or 0), int(b["port"]), str(b["csrf"]), str(b.get("scheme") or ""))
            if not any(x[1] == b_item[1] and x[2] == b_item[2] for x in initial_targets):
                initial_targets.append(b_item)

    data = None
    hit_pid, hit_port, hit_csrf, hit_scheme = 0, 0, "", ""

    for pid, port, csrf, pref_scheme in initial_targets:
        data, hit_scheme = _probe_ls_get_user_status(port, csrf, pref_scheme)
        if data:
            hit_pid, hit_port, hit_csrf = pid, port, csrf
            break

    if not data:
        _LS_CACHE["port"] = 0
        _LS_CACHE["csrf"] = ""
        _LS_CACHE["scheme"] = ""
        for pid, port, csrf in _discover_ls_candidates():
            data, hit_scheme = _probe_ls_get_user_status(port, csrf)
            if data:
                hit_pid, hit_port, hit_csrf = pid, port, csrf
                save_json(bridge_path, {"scheme": hit_scheme, "port": hit_port, "csrf": hit_csrf, "pid": hit_pid})
                break

    if not data:
        return _LS_CACHE["quotas"]

    _LS_CACHE["scheme"] = hit_scheme
    _LS_CACHE["port"] = hit_port
    _LS_CACHE["csrf"] = hit_csrf

    user_status = data.get("userStatus", {})
    plan_info = user_status.get("planStatus", {}).get("planInfo", {})
    if plan_info.get("planName"):
        _LS_CACHE["plan_name"] = str(plan_info["planName"])

    configs = user_status.get("cascadeModelConfigData", {}).get("clientModelConfigs", [])
    quotas = {}
    now_utc = datetime.now(timezone.utc)

    for c in configs:
        label = str(c.get("label") or "")
        mid = str(c.get("modelId") or "")
        ph = str((c.get("modelOrAlias") or {}).get("model") or "")
        mkey = map_raw_model_key(f"{label} {mid}", ph)
        if not mkey:
            continue
        parsed = _parse_model_quota_entry(c, now_utc)
        # Prefer enabled variant or '-high' if multiple tiers exist for the same canonical model
        if mkey not in quotas or (not parsed["disabled"] and ("high" in mid.lower() or quotas[mkey]["disabled"])):
            quotas[mkey] = parsed

    for a, b in _SHARED_POOL_PARTNERS:
        if a in quotas and b not in quotas and not quotas[a]["disabled"]:
            quotas[b] = dict(quotas[a])
        elif b in quotas and a not in quotas and not quotas[b]["disabled"]:
            quotas[a] = dict(quotas[b])

    if quotas:
        _LS_CACHE["quotas"] = quotas
    return _LS_CACHE["quotas"]


class _STARTUPINFOW(ctypes.Structure):
    _fields_ = [
        ("cb", ctypes.c_ulong),
        ("lpReserved", ctypes.c_wchar_p),
        ("lpDesktop", ctypes.c_wchar_p),
        ("lpTitle", ctypes.c_wchar_p),
        ("dwX", ctypes.c_ulong),
        ("dwY", ctypes.c_ulong),
        ("dwXSize", ctypes.c_ulong),
        ("dwYSize", ctypes.c_ulong),
        ("dwXCountChars", ctypes.c_ulong),
        ("dwYCountChars", ctypes.c_ulong),
        ("dwFillAttribute", ctypes.c_ulong),
        ("dwFlags", ctypes.c_ulong),
        ("wShowWindow", ctypes.c_ushort),
        ("cbReserved2", ctypes.c_ushort),
        ("lpReserved2", ctypes.c_void_p),
        ("hStdInput", ctypes.c_void_p),
        ("hStdOutput", ctypes.c_void_p),
        ("hStdError", ctypes.c_void_p),
    ]

class _PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("hProcess", ctypes.c_void_p),
        ("hThread", ctypes.c_void_p),
        ("dwProcessId", ctypes.c_ulong),
        ("dwThreadId", ctypes.c_ulong),
    ]


def start_desktop_pet():
    global DESKTOP_PET_PROC
    if is_desktop_pet_running():
        return True
    if not os.path.exists(WIDGET_PS1):
        return False
    try:
        # Always target interactive user desktop WinSta0\Default so the pet is visible even when Sidecar runs in exebox!
        si = _STARTUPINFOW()
        si.cb = ctypes.sizeof(_STARTUPINFOW)
        si.lpDesktop = "WinSta0\\Default"
        si.dwFlags = 0x00000001  # STARTF_USESHOWWINDOW
        si.wShowWindow = 0       # SW_HIDE console window
        pi = _PROCESS_INFORMATION()
        cmd = f'powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{WIDGET_PS1}"'
        cmd_buf = ctypes.create_unicode_buffer(cmd)
        CREATE_NEW_PROCESS_GROUP = 0x00000200
        CREATE_NO_WINDOW = 0x08000000
        ok = ctypes.windll.kernel32.CreateProcessW(
            None,
            cmd_buf,
            None,
            None,
            False,
            CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW,
            None,
            PLUGIN_DIR,
            ctypes.byref(si),
            ctypes.byref(pi)
        )
        if ok:
            try:
                with open(PID_FILE, "w", encoding="ascii") as f:
                    f.write(str(pi.dwProcessId))
            except Exception:
                pass
            ctypes.windll.kernel32.CloseHandle(pi.hThread)
            ctypes.windll.kernel32.CloseHandle(pi.hProcess)
            return True
    except Exception:
        pass
    try:
        flags = 0x00000200
        DESKTOP_PET_PROC = subprocess.Popen(
            ["powershell.exe", "-STA", "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", WIDGET_PS1],
            cwd=PLUGIN_DIR,
            creationflags=flags,
            close_fds=True
        )
        return True
    except Exception:
        return False



USER_MANUALLY_STOPPED = False


def _is_antigravity_process(pid):
    try:
        hProc = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
        if hProc:
            buf = ctypes.create_unicode_buffer(512)
            size = ctypes.wintypes.DWORD(512)
            ctypes.windll.kernel32.QueryFullProcessImageNameW(hProc, 0, buf, ctypes.byref(size))
            ctypes.windll.kernel32.CloseHandle(hProc)
            name = os.path.basename(buf.value).lower()
            return "antigravity" in name
    except Exception:
        pass
    return False


def has_antigravity_window():
    try:
        hdesk = ctypes.windll.user32.OpenDesktopW("Default", 0, False, 0x10000000)
        if not hdesk:
            hdesk = ctypes.windll.user32.OpenInputDesktop(0, False, 0x10000000)
        if not hdesk:
            return False

        found = [False]
        WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.wintypes.HWND, ctypes.wintypes.LPARAM)

        def cb(hwnd, _):
            try:
                if not ctypes.windll.user32.IsWindow(hwnd):
                    return True

                pid = ctypes.wintypes.DWORD()
                ctypes.windll.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
                if pid.value <= 0 or not _is_antigravity_process(pid.value):
                    return True

                cls_buf = ctypes.create_unicode_buffer(128)
                ctypes.windll.user32.GetClassNameW(hwnd, cls_buf, 128)
                if cls_buf.value != "Chrome_WidgetWin_1":
                    return True

                length = ctypes.windll.user32.GetWindowTextLengthW(hwnd)
                if length > 0:
                    buf = ctypes.create_unicode_buffer(length + 1)
                    ctypes.windll.user32.GetWindowTextW(hwnd, buf, length + 1)
                    title = buf.value
                    if "Gemini Hakimi" in title:
                        return True

                    rect = (ctypes.c_int * 4)()
                    ctypes.windll.user32.GetWindowRect(hwnd, ctypes.byref(rect))
                    w = rect[2] - rect[0]
                    h = rect[3] - rect[1]
                    is_vis = bool(ctypes.windll.user32.IsWindowVisible(hwnd))
                    is_ico = bool(ctypes.windll.user32.IsIconic(hwnd))

                    # Active window on screen or minimized in taskbar
                    if (is_vis and w >= 400 and h >= 300) or is_ico or rect[0] <= -10000:
                        found[0] = True
                        return False
            except Exception:
                pass
            return True

        ctypes.windll.user32.EnumDesktopWindows(hdesk, WNDENUMPROC(cb), 0)
        ctypes.windll.user32.CloseDesktop(hdesk)
        return found[0]
    except Exception:
        return False


def _companion_watcher_loop():
    r"""Background companion watcher that manages automatic desktop pet life-cycle."""
    global USER_MANUALLY_STOPPED
    while True:
        try:
            time.sleep(1.5)
            has_host = has_antigravity_window()
            if not has_host:
                # Host closed -> Reset manual stop so it auto-launches on next Antigravity start!
                USER_MANUALLY_STOPPED = False
            else:
                cfg = get_config()
                # If either auto-launch or companion follow is enabled
                if cfg.get("auto_launch_desktop_pet") or cfg.get("hide_with_antigravity"):
                    if not is_desktop_pet_running() and not USER_MANUALLY_STOPPED:
                        print("[HakimiCompanion] Antigravity window active, auto-launching desktop pet on WinSta0\\Default...", flush=True)
                        start_desktop_pet()
        except Exception:
            pass

def stop_desktop_pet():
    global DESKTOP_PET_PROC
    if DESKTOP_PET_PROC is not None:
        try:
            DESKTOP_PET_PROC.terminate()
        except Exception:
            pass
        DESKTOP_PET_PROC = None
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE, "r", encoding="ascii", errors="ignore") as f:
                pid = int(f.read().strip())
            if _is_pid_alive(pid):
                os.kill(pid, signal.SIGTERM)
        except Exception:
            pass
        try:
            os.remove(PID_FILE)
        except Exception:
            pass
    return False


def _resolve_active_model(cfg, models_dict, latest_conv_model=None, latest_step_sig=None):
    global _LAST_PBTXT_MODEL, _LAST_STEP_MODEL_SIG
    detected_model = detect_antigravity_active_model()
    active_model = cfg.get("active_model")
    target_detected = latest_conv_model if (latest_conv_model and latest_conv_model in models_dict) else detected_model

    step_changed = bool(latest_step_sig and latest_step_sig != _LAST_STEP_MODEL_SIG)
    pbtxt_changed = bool(detected_model and detected_model in models_dict and detected_model != _LAST_PBTXT_MODEL)

    if step_changed or pbtxt_changed:
        if latest_step_sig:
            _LAST_STEP_MODEL_SIG = latest_step_sig
        if detected_model and detected_model in models_dict:
            _LAST_PBTXT_MODEL = detected_model
        if target_detected and target_detected in models_dict and active_model != target_detected:
            active_model = target_detected
            cfg["active_model"] = active_model
            save_json(CONFIG_PATH, cfg)
    if not active_model or active_model not in models_dict:
        active_model = target_detected if target_detected in models_dict else "gemini-4-hydrogen"
    return active_model, (target_detected if target_detected in models_dict else detected_model)


_STATS_LOCK = threading.Lock()
_STATS_CACHE = {}


def collect_stats(requested_conv_id=None, force_refresh=False):
    cache_key = requested_conv_id or ""
    with _STATS_LOCK:
        cached = _STATS_CACHE.get(cache_key)
        if not force_refresh and cached and (time.time() - cached["ts"] < 1.5):
            return cached["data"]
        result = _collect_stats_uncached(requested_conv_id)
        _STATS_CACHE[cache_key] = {"ts": time.time(), "data": result}
        return result


def _collect_stats_uncached(requested_conv_id=None):
    cfg = get_config()
    pricing = get_pricing()
    models_dict = pricing.get("models", {})
    rate = float(pricing.get("usd_to_cny", 7.25))
    pbtxt_detected = detect_antigravity_active_model()

    pattern = os.path.join(BRAIN_DIR, "*", ".system_generated", "logs", "transcript.jsonl")
    files = glob.glob(pattern)
    files.sort(key=lambda p: os.path.getmtime(p) if os.path.exists(p) else 0, reverse=True)

    now_utc = datetime.now(timezone.utc)
    today_utc_str = now_utc.strftime("%Y-%m-%d")
    today_local_str = datetime.now().strftime("%Y-%m-%d")
    now_ts = time.time()

    active_entry = None
    if requested_conv_id and requested_conv_id not in ("", "current", "null", "undefined"):
        target_path = os.path.join(BRAIN_DIR, requested_conv_id, ".system_generated", "logs", "transcript.jsonl")
        if os.path.exists(target_path):
            active_entry = parse_transcript_file(target_path)

    if active_entry is None and files:
        active_entry = parse_transcript_file(files[0])

    s_conv_id = active_entry["conv_id"] if active_entry else ""
    s_steps = active_entry["steps"] if active_entry else []
    active_cm = get_conv_step_models(s_conv_id, pbtxt_detected) if s_conv_id else {
        "step_map": {}, "latest_model": pbtxt_detected, "latest_invoked_id": pbtxt_detected, "latest_enum": ""
    }

    last_step_idx = s_steps[-1]["step_index"] if s_steps else 0
    last_step_info = active_cm["step_map"].get(last_step_idx) if s_steps else None
    last_step_model = (last_step_info[0] if last_step_info else active_cm.get("latest_model")) or pbtxt_detected
    last_step_invoked_id = (last_step_info[1] if last_step_info else active_cm.get("latest_invoked_id")) or last_step_model
    latest_step_sig = (s_conv_id, last_step_idx, last_step_model) if s_conv_id and s_steps else None

    active_model, detected_model = _resolve_active_model(
        cfg,
        models_dict,
        latest_conv_model=last_step_model,
        latest_step_sig=latest_step_sig,
    )
    active_plan = cfg.get("active_plan", "free")
    fallback_info = {"display_name": active_model, "context_window": 1048576, "tiers": [{"hit": 0.075, "miss": 0.75, "out": 3.75}]}
    model_info = models_dict.get(active_model, fallback_info)
    ctx_window = int(model_info.get("context_window") or pricing.get("context_window") or 1048576)
    limits_cfg = pricing.get("limits", {}).get(active_plan, {"rpm": 15, "tpm": 1000000, "rpd": 1500})

    t_turns = 0
    t_inp = 0
    t_cache = 0
    t_out = 0
    today_cost_usd = 0.0
    today_savings_usd = 0.0
    rpm_count = 0
    tpm_tokens = 0

    featured_models = [
        "gemini-4-hydrogen",
        "gemini-3.8-flash",
        "gemini-4-argon",
        "claude-opus-5-5",
        "claude-sonnet-5-5",
        "gemini-4-carbon",
    ]
    pool_buckets = {}
    for mk in featured_models:
        pname = models_dict.get(mk, {}).get("quota_pool", mk)
        if pname not in pool_buckets:
            pool_buckets[pname] = {"t5": 0, "tok5": 0, "t7": 0, "tok7": 0, "oldest_5h": None, "oldest_7d": None}

    for fp in files:
        try:
            mtime = os.path.getmtime(fp)
        except OSError:
            continue
        if now_ts - mtime > 7 * 86400:
            break
        entry = parse_transcript_file(fp)
        if not entry:
            continue
        cid = entry.get("conv_id") or ""
        cm = active_cm if (cid and cid == s_conv_id) else get_conv_step_models(cid, detected_model)
        step_map = cm.get("step_map", {})
        conv_fb_model = cm.get("latest_model") or detected_model or active_model
        if conv_fb_model not in models_dict:
            conv_fb_model = active_model
        for s in entry["steps"]:
            s_info = step_map.get(s["step_index"])
            s_model = (s_info[0] if s_info else conv_fb_model) or active_model
            if s_model not in models_dict:
                s_model = active_model
            c_str = s["created_at"][:10]
            if c_str in (today_utc_str, today_local_str):
                t_turns += 1
                t_inp += s["input_tokens"]
                t_cache += s["cache_read_tokens"]
                t_out += s["output_tokens"]
                sc_step = calculate_cost(s["input_tokens"], s["cache_read_tokens"], s["output_tokens"], s_model, pricing)
                today_cost_usd += sc_step["raw_cost_usd"]
                today_savings_usd += sc_step["raw_savings_usd"]
            ts = s["ts"]
            if ts > 0:
                age = now_ts - ts
                if age <= 60.0:
                    rpm_count += 1
                    tpm_tokens += s["total_tokens"]
                if age <= 7 * 86400:
                    pname = models_dict.get(s_model, {}).get("quota_pool", s_model)
                    pb = pool_buckets.get(pname)
                    if pb is not None:
                        eff_tok = s["input_tokens"] + s["output_tokens"] + int(s["cache_read_tokens"] * 0.08)
                        if pb["oldest_7d"] is None or ts < pb["oldest_7d"]:
                            pb["oldest_7d"] = ts
                        pb["t7"] += 1
                        pb["tok7"] += eff_tok
                        if age <= 5 * 3600:
                            if pb["oldest_5h"] is None or ts < pb["oldest_5h"]:
                                pb["oldest_5h"] = ts
                            pb["t5"] += 1
                            pb["tok5"] += eff_tok

    today_cost = {
        "cost_usd": round(today_cost_usd, 5),
        "cost_cny": round(today_cost_usd * rate, 4),
        "savings_usd": round(today_savings_usd, 5),
        "savings_cny": round(today_savings_usd * rate, 4),
    }
    today_hit_rate = round((t_cache / (t_inp + t_cache)) * 100, 1) if (t_inp + t_cache) > 0 else 0.0

    s_inp = sum(x["input_tokens"] for x in s_steps)
    s_cache = sum(x["cache_read_tokens"] for x in s_steps)
    s_out = sum(x["output_tokens"] for x in s_steps)
    s_tot = s_inp + s_cache + s_out

    s_step_map = active_cm.get("step_map", {})
    s_fb_model = active_cm.get("latest_model") or active_model
    if s_fb_model not in models_dict:
        s_fb_model = active_model
    s_fb_invoked = active_cm.get("latest_invoked_id") or s_fb_model

    s_cost_usd = 0.0
    s_savings_usd = 0.0
    for x in s_steps:
        x_info = s_step_map.get(x["step_index"])
        x_model = (x_info[0] if x_info else s_fb_model) or active_model
        if x_model not in models_dict:
            x_model = active_model
        xc = calculate_cost(x["input_tokens"], x["cache_read_tokens"], x["output_tokens"], x_model, pricing)
        s_cost_usd += xc["raw_cost_usd"]
        s_savings_usd += xc["raw_savings_usd"]

    s_cost = {
        "cost_usd": round(s_cost_usd, 5),
        "cost_cny": round(s_cost_usd * rate, 4),
        "savings_usd": round(s_savings_usd, 5),
        "savings_cny": round(s_savings_usd * rate, 4),
    }
    s_hit_rate = round((s_cache / (s_inp + s_cache)) * 100, 1) if (s_inp + s_cache) > 0 else 0.0

    if s_steps:
        last_s = s_steps[-1]
        ls_info = s_step_map.get(last_s["step_index"])
        ls_model = (ls_info[0] if ls_info else s_fb_model) or active_model
        if ls_model not in models_dict:
            ls_model = active_model
        ls_invoked_id = (ls_info[1] if ls_info else s_fb_invoked) or ls_model
        ls_short = models_dict.get(ls_model, {}).get("short_name", ls_model)
        lt_cost = calculate_cost(last_s["input_tokens"], last_s["cache_read_tokens"], last_s["output_tokens"], ls_model, pricing)
        last_turn = {
            "step_index": last_s["step_index"],
            "model": ls_model,
            "model_short": ls_short,
            "invoked_model_id": ls_invoked_id,
            "input_tokens": last_s["input_tokens"],
            "cache_read_tokens": last_s["cache_read_tokens"],
            "output_tokens": last_s["output_tokens"],
            "total_tokens": last_s["total_tokens"],
            "cache_hit_rate": last_s["cache_hit_rate"],
            "cost_usd": lt_cost["cost_usd"],
            "cost_cny": lt_cost["cost_cny"],
            "savings_usd": lt_cost["savings_usd"],
            "savings_cny": lt_cost["savings_cny"],
            "created_at": last_s["created_at"]
        }
        cur_ctx = last_s["total_tokens"]
    else:
        ls_model = active_model
        ls_invoked_id = last_step_invoked_id or active_model
        last_turn = {
            "step_index": 0,
            "model": ls_model,
            "model_short": models_dict.get(ls_model, {}).get("short_name", ls_model),
            "invoked_model_id": ls_invoked_id,
            "input_tokens": 0,
            "cache_read_tokens": 0,
            "output_tokens": 0,
            "total_tokens": 0,
            "cache_hit_rate": 0.0,
            "cost_usd": 0.0,
            "cost_cny": 0.0,
            "savings_usd": 0.0,
            "savings_cny": 0.0,
            "created_at": ""
        }
        cur_ctx = 0

    ctx_pct = round((cur_ctx / ctx_window) * 100, 1) if ctx_window > 0 else 0.0

    recent_turns = []
    for idx, st_item in enumerate(s_steps[-12:]):
        turn_num = max(1, len(s_steps) - len(s_steps[-12:]) + idx + 1)
        st_info = s_step_map.get(st_item["step_index"])
        st_model = (st_info[0] if st_info else s_fb_model) or active_model
        if st_model not in models_dict:
            st_model = active_model
        st_invoked_id = (st_info[1] if st_info else s_fb_invoked) or st_model
        st_short = models_dict.get(st_model, {}).get("short_name", st_model)
        c_item = calculate_cost(st_item["input_tokens"], st_item["cache_read_tokens"], st_item["output_tokens"], st_model, pricing)
        recent_turns.append({
            "turn": turn_num,
            "step_index": st_item["step_index"],
            "model": st_model,
            "model_short": st_short,
            "invoked_model_id": st_invoked_id,
            "input_tokens": st_item["input_tokens"],
            "cache_read_tokens": st_item["cache_read_tokens"],
            "output_tokens": st_item["output_tokens"],
            "total_tokens": st_item["total_tokens"],
            "cache_hit_rate": st_item["cache_hit_rate"],
            "cost_cny": c_item["cost_cny"],
            "savings_cny": c_item["savings_cny"],
            "query": st_item.get("query") or ""
        })
    recent_turns.reverse()

    tomorrow_utc = (now_utc + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    diff_sec = max(0, int((tomorrow_utc - now_utc).total_seconds()))
    rem_h = diff_sec // 3600
    rem_m = (diff_sec % 3600) // 60
    rem_s = diff_sec % 60
    reset_countdown = f"{rem_h:02d}:{rem_m:02d}:{rem_s:02d}"

    models_list = [
        {"id": k, "name": v.get("display_name", k), "note": v.get("note", "")}
        for k, v in pricing.get("models", {}).items()
    ]

    mult = float(limits_cfg.get("quota_multiplier", 5.0 if active_plan == "tier1" else 1.0))

    live_quotas = fetch_live_antigravity_quotas()
    model_quotas = []
    active_mq = None

    for mk in featured_models:
        minfo = pricing.get("models", {}).get(mk)
        if not minfo:
            continue
        quota_pool = str(minfo.get("quota_pool") or mk)
        pool_label = str(minfo.get("pool_label") or "独立池")
        pb = pool_buckets.get(quota_pool, {"t5": 0, "tok5": 0, "t7": 0, "tok7": 0, "oldest_5h": None, "oldest_7d": None})

        l5_t = max(1, int(round(int(minfo.get("quota_5h_turns", 1200)) * mult)))
        l5_tok = max(1, int(round(int(minfo.get("quota_5h_tokens", 45000000)) * mult)))
        l7_t = max(1, int(round(int(minfo.get("quota_weekly_turns", 7000)) * mult)))
        l7_tok = max(1, int(round(int(minfo.get("quota_weekly_tokens", 280000000)) * mult)))

        u5 = min(100, max(0, int(round(max((pb["t5"] / l5_t) * 100.0, (pb["tok5"] / l5_tok) * 100.0)))))
        u7 = min(100, max(0, int(round(max((pb["t7"] / l7_t) * 100.0, (pb["tok7"] / l7_tok) * 100.0)))))
        rem5 = max(0, 100 - u5)
        rem7 = max(0, 100 - u7)

        r5_dt = datetime.fromtimestamp((pb["oldest_5h"] + 5 * 3600) if pb["oldest_5h"] else (now_ts + 5 * 3600))
        r7_dt = datetime.fromtimestamp((pb["oldest_7d"] + 7 * 86400) if pb["oldest_7d"] else (now_ts + 7 * 86400))
        r5_str = "本地估算 " + r5_dt.strftime("%H:%M")
        r7_str = "本地估算 " + r7_dt.strftime("%m-%d %H:%M")

        disabled = (mk == "gemini-4-carbon")
        is_weekly = False
        pct = 0 if disabled else rem5
        reset_str = "暂不可用 · 需 Ultra" if disabled else r5_str
        window_label = "Unavailable" if disabled else "本地估算 5h"

        if mk in live_quotas:
            lq = live_quotas[mk]
            disabled = bool(lq.get("disabled"))
            is_weekly = bool(lq.get("is_weekly"))
            pct = int(lq.get("pct", 100))
            reset_str = str(lq.get("reset", "实时同步"))
            window_label = str(lq.get("window_label", "多日周期池" if is_weekly else "5h 周期池"))
            if disabled:
                rem5 = 0
                rem7 = 0
                r5_str = reset_str
                r7_str = "需 Ultra 订阅"
            elif is_weekly:
                rem7 = pct
                r7_str = reset_str
                rem5 = pct
                r5_str = pool_label
            else:
                rem5 = pct
                r5_str = reset_str
                rem7 = pct
                r7_str = pool_label
        elif disabled:
            rem5 = 0
            rem7 = 0
            r5_str = reset_str
            r7_str = "需 Ultra 订阅"

        mq_item = {
            "id": mk,
            "name": minfo.get("display_name", mk),
            "short_name": minfo.get("short_name", mk),
            "vendor": minfo.get("vendor", "Gemini"),
            "badge": minfo.get("badge", "PRO"),
            "quota_pool": quota_pool,
            "pool_label": pool_label,
            "window_label": window_label,
            "is_weekly": is_weekly,
            "disabled": disabled,
            "remaining_pct": pct,
            "reset_display": reset_str,
            "is_active": (mk == active_model),
            "five_hour_remaining_pct": rem5,
            "five_hour_used_turns": pb["t5"],
            "five_hour_limit_turns": l5_t,
            "five_hour_reset": r5_str,
            "weekly_remaining_pct": rem7,
            "weekly_used_turns": pb["t7"],
            "weekly_limit_turns": l7_t,
            "weekly_reset": r7_str,
        }
        model_quotas.append(mq_item)
        if mk == active_model:
            active_mq = mq_item

    if active_mq is None and model_quotas:
        active_mq = model_quotas[0]

    active_pool = active_mq["quota_pool"] if active_mq else "flash_hydrogen"
    companion_target = "gemini-3.8-flash" if active_pool == "argon" else "gemini-4-argon"
    companion_mq = next((x for x in model_quotas if x["id"] == companion_target and not x["disabled"]), None)
    if companion_mq is None:
        companion_mq = next((x for x in model_quotas if x["quota_pool"] != active_pool and not x["disabled"]), active_mq)

    active_5h = {
        "remaining_pct": active_mq["remaining_pct"] if active_mq else 100,
        "used_turns": active_mq["five_hour_used_turns"] if active_mq else 0,
        "limit_turns": active_mq["five_hour_limit_turns"] if active_mq else 1500,
        "reset_display": active_mq["reset_display"] if active_mq else "实时同步",
        "pool_label": active_mq["pool_label"] if active_mq else "独立池",
        "window_label": active_mq["window_label"] if active_mq else "5h 周期池",
        "disabled": bool(active_mq["disabled"]) if active_mq else False,
    }
    active_7d = {
        "remaining_pct": companion_mq["remaining_pct"] if companion_mq else 100,
        "used_turns": companion_mq["weekly_used_turns"] if companion_mq else 0,
        "limit_turns": companion_mq["weekly_limit_turns"] if companion_mq else 9000,
        "reset_display": companion_mq["reset_display"] if companion_mq else "实时同步",
        "short_label": "Flash/H" if (companion_mq and companion_mq["quota_pool"] == "flash_hydrogen") else (companion_mq["short_name"] if companion_mq else "Argon"),
        "pool_label": companion_mq["pool_label"] if companion_mq else "独立池",
    }

    return {
        "five_hour": active_5h,
        "weekly": active_7d,
        "companion_pool": active_7d,
        "live_plan_name": _LS_CACHE.get("plan_name", ""),
        "model_quotas": model_quotas,
        "ok": True,
        "config": {
            "active_model": active_model,
            "active_model_name": model_info.get("display_name", active_model),
            "invoked_model_id": last_step_invoked_id or active_model,
            "active_plan": active_plan,
            "sound_enabled": bool(cfg.get("sound_enabled", True)),
            "cache_sound_enabled": bool(cfg.get("cache_sound_enabled", False)),
            "speech_bubble_enabled": bool(cfg.get("speech_bubble_enabled", True)),
            "auto_launch_desktop_pet": bool(cfg.get("auto_launch_desktop_pet", False)),
            "follow_antigravity": bool(cfg.get("follow_antigravity", True)),
            "hide_with_antigravity": bool(cfg.get("hide_with_antigravity", True))
        },
        "models": models_list,
        "desktop_pet_running": is_desktop_pet_running(),
        "last_turn": last_turn,
        "session": {
            "conv_id": s_conv_id,
            "title": get_conversation_title(s_conv_id),
            "turns": len(s_steps),
            "input_tokens": s_inp,
            "cache_read_tokens": s_cache,
            "output_tokens": s_out,
            "total_tokens": s_tot,
            "cache_hit_rate": s_hit_rate,
            "current_context": cur_ctx,
            "context_pct": ctx_pct,
            "cost_usd": s_cost["cost_usd"],
            "cost_cny": s_cost["cost_cny"],
            "savings_usd": s_cost["savings_usd"],
            "savings_cny": s_cost["savings_cny"],
            "recent_turns": recent_turns
        },
        "today": {
            "turns": t_turns,
            "input_tokens": t_inp,
            "cache_read_tokens": t_cache,
            "output_tokens": t_out,
            "total_tokens": t_inp + t_cache + t_out,
            "cache_hit_rate": today_hit_rate,
            "cost_usd": today_cost["cost_usd"],
            "cost_cny": today_cost["cost_cny"],
            "savings_usd": today_cost["savings_usd"],
            "savings_cny": today_cost["savings_cny"]
        },
        "rate_limits": {
            "current_rpm": rpm_count,
            "max_rpm": int(limits_cfg.get("rpm", 15)),
            "current_tpm": tpm_tokens,
            "max_tpm": int(limits_cfg.get("tpm", 1000000)),
            "current_tps": round(tpm_tokens / 60.0, 1),
            "max_tps": round(int(limits_cfg.get("tpm", 1000000)) / 60.0, 1),
            "current_rpd": t_turns,
            "max_rpd": int(limits_cfg.get("rpd", 1500)),
            "context_window": ctx_window,
            "reset_countdown": reset_countdown
        }
    }


MIME_MAP = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".wav": "audio/wav",
    ".mp3": "audio/mpeg",
    ".gif": "image/gif",
    ".svg": "image/svg+xml"
}


class HakimiSidecarHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _send_cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Sidecar-Token")

    def do_OPTIONS(self):
        self.send_response(204)
        self._send_cors()
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path in ("/", "/ui.html"):
            ui_file = os.path.join(SIDE_DIR, "ui.html")
            if os.path.exists(ui_file):
                with open(ui_file, "rb") as f:
                    content = f.read()
                self.send_response(200)
                self._send_cors()
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(content)
                return

        if path == "/preload.js":
            content = b"// Sidecar preload bridge\n"
            if os.path.exists(PRELOAD_JS_SDK):
                try:
                    with open(PRELOAD_JS_SDK, "rb") as f:
                        content = f.read()
                except Exception:
                    pass
            self.send_response(200)
            self._send_cors()
            self.send_header("Content-Type", "application/javascript; charset=utf-8")
            self.end_headers()
            self.wfile.write(content)
            return

        if path == "/health":
            self.send_response(200)
            self._send_cors()
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "plugin": "gemini-hakimi-widget"}).encode("utf-8"))
            return

        if path == "/api/quotes":
            quotes = load_json(QUOTES_PATH, {})
            self.send_response(200)
            self._send_cors()
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps(quotes, ensure_ascii=False).encode("utf-8"))
            return

        if path == "/api/stats":
            params = urllib.parse.parse_qs(parsed.query)
            cid = params.get("conversationId", [None])[0]
            data = collect_stats(cid)
            self.send_response(200)
            self._send_cors()
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps(data, ensure_ascii=False).encode("utf-8"))
            return

        if path.startswith("/assets/"):
            rel = path[len("/assets/"):].lstrip("/\\")
            full_path = os.path.abspath(os.path.join(ASSETS_DIR, rel))
            if full_path.startswith(os.path.abspath(ASSETS_DIR)) and os.path.isfile(full_path):
                ext = os.path.splitext(full_path)[1].lower()
                ctype = MIME_MAP.get(ext, "application/octet-stream")
                with open(full_path, "rb") as f:
                    data = f.read()
                self.send_response(200)
                self._send_cors()
                self.send_header("Content-Type", ctype)
                self.send_header("Cache-Control", "public, max-age=3600")
                self.end_headers()
                self.wfile.write(data)
                return

        self.send_response(404)
        self._send_cors()
        self.end_headers()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"
        try:
            payload = json.loads(body) if body.strip() else {}
        except Exception:
            payload = {}

        if path == "/api/config":
            cfg = get_config()
            for k in ("active_model", "active_plan", "sound_enabled", "cache_sound_enabled", "speech_bubble_enabled", "auto_launch_desktop_pet", "follow_antigravity", "hide_with_antigravity"):
                if k in payload:
                    cfg[k] = payload[k]
            save_json(CONFIG_PATH, cfg)
            with _STATS_LOCK:
                _STATS_CACHE.clear()
            self.send_response(200)
            self._send_cors()
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps(collect_stats(payload.get("conversationId"), force_refresh=True), ensure_ascii=False).encode("utf-8"))
            return

        if path == "/api/desktop-pet":
            global USER_MANUALLY_STOPPED
            action = payload.get("action", "toggle")
            running = is_desktop_pet_running()
            if action == "manual_exit" or action == "stop" or (action == "toggle" and running):
                USER_MANUALLY_STOPPED = True
                now_running = stop_desktop_pet()
            else:
                USER_MANUALLY_STOPPED = False
                now_running = start_desktop_pet()
            self.send_response(200)
            self._send_cors()
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps({"ok": True, "desktop_pet_running": now_running}).encode("utf-8"))
            return

        self.send_response(404)
        self._send_cors()
        self.end_headers()


def write_server_info(port):
    token = (
        os.environ.get("ANTIGRAVITY_SIDECAR_UI_TOKEN")
        or os.environ.get("ANTIGRAVITY_SIDECAR_AUTH_TOKEN")
        or os.environ.get("ANTIGRAVITY_SIDECAR_WEB_TOKEN")
    )
    info = {
        "host": "127.0.0.1",
        "port": port,
        "token": token,
        "pid": os.getpid()
    }
    candidates = [
        os.path.join(AGY_DIR, "sidecar_data", "gemini-hakimi-widget", "hakimi_panel", "data", "server_info.json"),
        os.path.join(AGY_DIR, "sidecar_data", "hakimi_panel", "data", "server_info.json")
    ]
    env_dir = os.environ.get("ANTIGRAVITY_EXECUTABLE_DATA_DIR")
    if env_dir:
        candidates.insert(0, os.path.join(env_dir, "server_info.json"))
    for p in candidates:
        try:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as f:
                json.dump(info, f, indent=2)
        except Exception:
            pass


def main():
    port_env = os.environ.get("ANTIGRAVITY_SIDECAR_WEB_PORT") or os.environ.get("PORT")
    port = int(port_env) if port_env else 39282

    cfg = get_config()
    if cfg.get("auto_launch_desktop_pet"):
        start_desktop_pet()

    # Start companion auto-revive watcher loop
    threading.Thread(target=_companion_watcher_loop, daemon=True).start()

    server = ThreadingHTTPServer(("127.0.0.1", port), HakimiSidecarHandler)
    write_server_info(port)
    if port != 54716:
        try:
            compat_srv = ThreadingHTTPServer(("127.0.0.1", 54716), HakimiSidecarHandler)
            threading.Thread(target=compat_srv.serve_forever, daemon=True).start()
            print("[HakimiSidecar] Also bound compatibility port 54716", flush=True)
        except Exception:
            pass
    print(f"[HakimiSidecar] Ready on http://127.0.0.1:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
