#!/usr/bin/env python3
"""Single status snapshot for the Omarchy 9Router bar widget.

Reads the 9Router dashboard's cookie-authenticated JSON endpoints and prints
one JSON object on stdout describing live model activity:

    {"ok": true, "authenticated": true, "active": [...], "recent": [...]}
    {"ok": true, "authenticated": false}
    {"ok": false, "error": "<short human-readable reason>"}

Authentication:
    The dashboard session lives in a cookie jar under
    ~/.local/state/omarchy/9router/cookies.txt. When ``--password-stdin`` is
    given, a fresh login is attempted first (the password arrives on stdin so
    it never appears in a process list). Otherwise the stored cookies are
    reused; a 401 simply reports ``authenticated: false`` and lets the caller
    decide whether to prompt for a password.

Data sources (first success wins):
    - GET /api/usage/stream  (SSE; first data: event wins, no waiting)
    - GET /api/usage/stats?period=7d
    - GET /api/usage/request-logs
    - GET /api/usage/history

Only stdlib is used. Never prints the password.

One-shot mode prints a single snapshot and always exits 0. Stream mode
(--stream) follows the SSE endpoint live, printing each data payload as one
JSON line; it exits 2 on HTTP 401 (session expired), 1 on network/stall
errors, and 0 on a clean stream end or --max-seconds expiry.
"""

import http.cookiejar
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 12
COOKIE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.join(os.path.expanduser("~"), ".local", "state")),
    "omarchy",
    "9router",
)
COOKIE_PATH = os.path.join(COOKIE_DIR, "cookies.txt")


def fail(reason):
    sys.stdout.write(json.dumps({"ok": False, "error": reason}) + "\n")
    sys.stdout.flush()


def build_opener():
    jar = http.cookiejar.MozillaCookieJar(COOKIE_PATH)
    try:
        if os.path.exists(COOKIE_PATH):
            jar.load(ignore_discard=True, ignore_expires=True)
    except OSError:
        pass
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("User-Agent", "omarchy-9router-monitor/1.0")]
    return opener, jar


def get(opener, base, path):
    url = base.rstrip("/") + path
    try:
        with opener.open(url, timeout=TIMEOUT) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read()
        except OSError:
            body = b""
        return exc.code, body
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError("cannot reach dashboard: %s" % exc)


def do_login(opener, jar, base, password):
    payload = json.dumps({"password": password}).encode("utf-8")
    request = urllib.request.Request(
        base.rstrip("/") + "/api/auth/login",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with opener.open(request, timeout=TIMEOUT) as resp:
            status = resp.status
            try:
                body = json.loads(resp.read().decode("utf-8", "replace") or "{}")
            except ValueError:
                body = {}
    except urllib.error.HTTPError as exc:
        try:
            raw = exc.read().decode("utf-8", "replace")
        except OSError:
            raw = ""
        try:
            body = json.loads(raw or "{}")
        except ValueError:
            body = {}
        status = exc.code
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError("cannot reach dashboard: %s" % exc)
    if status == 429:
        raise RuntimeError(
            "dashboard locked after too many attempts (%s)"
            % (body.get("error") or "try again later")
        )
    if status == 403 and body.get("mustChangePassword"):
        raise RuntimeError(
            "dashboard password must be changed on the local machine first"
        )
    if status != 200 or not body.get("success"):
        raise RuntimeError(body.get("error") or "login rejected")
    try:
        os.makedirs(COOKIE_DIR, mode=0o700, exist_ok=True)
        jar.save(ignore_discard=True, ignore_expires=True)
        os.chmod(COOKIE_PATH, 0o600)
    except OSError:
        pass
    return True


def parse_sse_first_data(raw):
    if isinstance(raw, (bytes, bytearray)):
        text = bytes(raw).decode("utf-8", "replace")
    else:
        text = str(raw)
    for chunk in text.split("\n\n"):
        for line in chunk.splitlines():
            line = line.strip()
            if line.startswith("data:"):
                payload = line[len("data:"):].strip()
                try:
                    return json.loads(payload)
                except ValueError:
                    continue
    return None


def norm_active(items):
    out = []
    if not isinstance(items, list):
        return out
    for entry in items:
        if not isinstance(entry, dict):
            continue
        model = str(entry.get("model") or "").strip()
        if not model:
            continue
        out.append(
            {
                "model": model,
                "provider": str(entry.get("provider") or "").strip(),
                "account": str(entry.get("account") or "").strip(),
                "count": int(entry.get("count") or 1),
            }
        )
    return out


def norm_recent(items):
    out = []
    if not isinstance(items, list):
        return out
    for entry in items:
        if not isinstance(entry, dict):
            continue
        model = str(entry.get("model") or "").strip()
        if not model:
            continue
        out.append(
            {
                "model": model,
                "provider": str(entry.get("provider") or "").strip(),
                "timestamp": str(entry.get("timestamp") or ""),
                "status": str(entry.get("status") or "ok"),
            }
        )
        if len(out) >= 20:
            break
    return out


def get_stream_first(opener, base, path):
    """Read just the first SSE data event, then hang up.

    /api/usage/stream never ends (25s keepalives), so a plain resp.read()
    would block until the socket times out. Read incrementally and stop at
    the first complete data payload. Returns (status, dict|None).
    """
    url = base.rstrip("/") + path
    try:
        resp = opener.open(url, timeout=TIMEOUT)
    except urllib.error.HTTPError as exc:
        return exc.code, None
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError("cannot reach dashboard: %s" % exc)
    try:
        if resp.status == 401:
            return 401, None
        buf = b""
        for _ in range(200):
            try:
                chunk = resp.read(65536)
            except (TimeoutError, OSError):
                break
            if not chunk:
                break
            buf += chunk
            if len(buf) > 1048576:
                break
            if b"\n\n" in buf:
                stats = parse_sse_first_data(buf)
                if isinstance(stats, dict):
                    return 200, stats
        stats = parse_sse_first_data(buf)
        return 200, stats if isinstance(stats, dict) else None
    finally:
        try:
            resp.close()
        except OSError:
            pass


def fetch_snapshot(opener, base):
    """Returns (snapshot_dict) or ("unauthorized",) or raises RuntimeError."""
    status, stats = get_stream_first(opener, base, "/api/usage/stream")
    if status == 401:
        return "unauthorized"
    if status == 200 and isinstance(stats, dict):
        return {
            "active": norm_active(stats.get("activeRequests")),
            "recent": norm_recent(stats.get("recentRequests")),
        }
    status, raw = get(opener, base, "/api/usage/stats?period=7d")
    if status == 401:
        return "unauthorized"
    if status == 200 and raw:
        try:
            stats = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            stats = None
        if isinstance(stats, dict):
            return {
                "active": norm_active(stats.get("activeRequests")),
                "recent": norm_recent(stats.get("recentRequests")),
            }
    status, raw = get(opener, base, "/api/usage/request-logs")
    if status == 401:
        return "unauthorized"
    if status == 200 and raw:
        try:
            logs = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            logs = None
        if isinstance(logs, dict) and isinstance(logs.get("logs"), list):
            logs = logs["logs"]
        if isinstance(logs, list) and logs and all(
            isinstance(e, dict) for e in logs
        ):
            return {"active": [], "recent": norm_recent(logs)}
    # Last resort: plain history, newest entry counts as the recent model.
    status, raw = get(opener, base, "/api/usage/history")
    if status == 401:
        return "unauthorized"
    if status == 200 and raw:
        try:
            stats = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            stats = None
        if isinstance(stats, dict):
            return {
                "active": norm_active(stats.get("activeRequests")),
                "recent": norm_recent(stats.get("recentRequests")),
            }
    raise RuntimeError("dashboard returned no usable usage data")


def emit_snapshot(stats):
    sys.stdout.write(
        json.dumps(
            {
                "ok": True,
                "authenticated": True,
                "active": norm_active(stats.get("activeRequests")),
                "recent": norm_recent(stats.get("recentRequests")),
            }
        )
        + "\n"
    )
    sys.stdout.flush()


def run_stream(opener, base, max_seconds):
    """Follow /api/usage/stream live, one JSON snapshot per SSE data event.

    The server pushes immediately on every request start/finish, so activity
    shows up in the bar instantly instead of at poll boundaries. Stalls (no
    bytes for 40s) or clean EOF return non-zero so the caller falls back to
    one-shot polling. Exits 2 on HTTP 401 (session expired), 1 on
    stalls/network errors, 0 on clean end or --max-seconds expiry.
    """
    url = base.rstrip("/") + "/api/usage/stream"
    try:
        resp = opener.open(url, timeout=TIMEOUT)
    except urllib.error.HTTPError as exc:
        return 2 if exc.code == 401 else 1
    except (urllib.error.URLError, TimeoutError, OSError):
        return 1
    if resp.status == 401:
        try:
            resp.close()
        except OSError:
            pass
        return 2
    try:
        sock = resp.fp.raw._sock
    except AttributeError:
        sock = None
    deadline = time.monotonic() + max_seconds if max_seconds > 0 else None
    buf = b""
    try:
        import select

        while True:
            if deadline is not None and time.monotonic() >= deadline:
                return 0
            if sock is not None:
                wait = 40.0
                if deadline is not None:
                    wait = max(0.5, min(40.0, deadline - time.monotonic()))
                try:
                    ready, _, _ = select.select([sock], [], [], wait)
                except (OSError, ValueError):
                    return 1
                if not ready:
                    return 1
            try:
                chunk = resp.read(65536)
            except (TimeoutError, OSError):
                return 1
            if not chunk:
                return 0
            buf += chunk
            if len(buf) > 1048576:
                buf = buf[-524288:]
            while b"\n\n" in buf:
                raw, buf = buf.split(b"\n\n", 1)
                text = raw.decode("utf-8", "replace")
                for line in text.splitlines():
                    line = line.strip()
                    if not line.startswith("data:"):
                        continue
                    try:
                        stats = json.loads(line[len("data:"):].strip())
                    except ValueError:
                        continue
                    if isinstance(stats, dict):
                        emit_snapshot(stats)
                    break
    finally:
        try:
            resp.close()
        except OSError:
            pass


def main(argv):
    base = "http://localhost:20128"
    login_with_stdin = False
    stream_mode = False
    max_seconds = 0
    for arg in argv[1:]:
        if arg.startswith("--base="):
            base = arg[len("--base="):]
        elif arg == "--password-stdin":
            login_with_stdin = True
        elif arg == "--stream":
            stream_mode = True
        elif arg.startswith("--max-seconds="):
            try:
                max_seconds = max(0, int(arg[len("--max-seconds="):]))
            except ValueError:
                max_seconds = 0
    parsed = urllib.parse.urlparse(base)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        if stream_mode:
            return 1
        fail("invalid dashboard URL")
        return 0

    opener, jar = build_opener()
    if login_with_stdin:
        # One line only: the caller keeps the pipe open after writing, so a
        # read-until-EOF here would hang forever.
        try:
            password = sys.stdin.readline().strip()
        except OSError:
            password = ""
        if not password:
            fail("empty password")
            return 0
        try:
            do_login(opener, jar, base, password)
        except RuntimeError as exc:
            if stream_mode:
                return 2 if "Invalid password" in str(exc) or "rejected" in str(exc) else 1
            fail("login failed: %s" % exc)
            return 0

    if stream_mode:
        return run_stream(opener, base, max_seconds)

    try:
        snapshot = fetch_snapshot(opener, base)
    except RuntimeError as exc:
        fail(str(exc))
        return 0
    if snapshot == "unauthorized":
        sys.stdout.write(json.dumps({"ok": True, "authenticated": False}) + "\n")
        sys.stdout.flush()
        return 0
    sys.stdout.write(
        json.dumps(
            {
                "ok": True,
                "authenticated": True,
                "active": snapshot.get("active", []),
                "recent": snapshot.get("recent", []),
            }
        )
        + "\n"
    )
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
