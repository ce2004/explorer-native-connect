#!/usr/bin/env python3
"""A stand-in for Explorer Native's ConnectServer (API v2, see API.md), used by the simulator tests.

Drive T:\\ is a temp folder seeded with test files. Drive G:\\ answers 503, like an unmounted Google Drive.
Run: python3 fake_server.py [--port 47810] [--code 12345678] [--root DIR]
"""
import argparse, datetime, json, math, os, shutil, struct, tempfile, threading, time, uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlsplit, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
ARGS = None
ROOT = None
JOBS = {}
UPLOADS = {}
PARTIALS = tempfile.mkdtemp(prefix="fakeuploads")
NATIVE = [".mp3", ".m4a", ".aac", ".flac", ".wav", ".aif", ".aiff", ".caf", ".alac"]
AUDIO = NATIVE + [".ogg", ".opus", ".wma", ".mp4", ".mov", ".m4v", ".mkv", ".webm", ".cda"]
LOCK = threading.Lock()


class HTTPError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def seed(root):
    os.makedirs(os.path.join(root, "Music"), exist_ok=True)
    os.makedirs(os.path.join(root, "Docs"), exist_ok=True)
    os.makedirs(os.path.join(root, "Drive"), exist_ok=True)
    with open(os.path.join(root, "Music", "clip.mp4"), "wb") as f:
        f.write(b"not really a video" * 50)
    shutil.copy(os.path.join(HERE, "fixtures", "tone.flac"), os.path.join(root, "Music", "tone.flac"))
    shutil.copy(os.path.join(HERE, "fixtures", "broken.ogg"), os.path.join(root, "Music", "a broken.ogg"))
    shutil.copy(os.path.join(HERE, "fixtures", "real.opus"), os.path.join(root, "Music", "b real.opus"))
    with open(os.path.join(root, "notes.txt"), "wb") as f:
        f.write(b"n" * 1229)
    with open(os.path.join(root, "Docs", "report.txt"), "w") as f:
        f.write("Quarterly report\n")
    with open(os.path.join(root, "Docs", "weird +&#% \u65e5\u672c.txt"), "w", encoding="utf-8") as f:
        f.write("odd name\n")


def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def local(path):
    """'T:\\a\\b' -> ROOT/a/b. G: is the unmounted Drive."""
    if not path or len(path) < 2 or path[1] != ":":
        raise HTTPError(400, "That isn't a full path.")
    letter = path[0].upper()
    if letter == "G":
        raise HTTPError(503, "Google Drive isn't mounted.")
    if letter != "T":
        raise HTTPError(404, "No such drive.")
    parts = [p for p in path[2:].replace("/", "\\").split("\\") if p]
    if any(p in ("..", ".") for p in parts):
        raise HTTPError(400, "Bad path.")
    return os.path.join(ROOT, *parts)


def remote(p):
    rel = os.path.relpath(p, ROOT)
    return "T:\\" if rel == "." else "T:\\" + rel.replace(os.sep, "\\")


def free_name(folder, name):
    base, ext = os.path.splitext(name)
    n = 2
    candidate = name
    while os.path.exists(os.path.join(folder, candidate)):
        candidate = f"{base} ({n}){ext}"
        n += 1
    return candidate


def tree_size(p):
    if os.path.isfile(p):
        return os.path.getsize(p), 1, 0
    b = f = d = 0
    for dirpath, dirnames, filenames in os.walk(p):
        d += len(dirnames)
        for fn in filenames:
            f += 1
            b += os.path.getsize(os.path.join(dirpath, fn))
    return b, f, d


def run_job(job, paths, dest, conflict, move):
    try:
        job["bytes"] = sum(tree_size(local(p))[0] for p in paths)
        target_dir = local(dest)
        for p in paths:
            if job["cancel"]:
                job["state"] = "cancelled"
                return
            src = local(p)
            name = os.path.basename(src)
            job["current"] = name
            time.sleep(0.4)
            target = os.path.join(target_dir, name)
            try:
                if os.path.abspath(target) == os.path.abspath(src) and not move:
                    target = os.path.join(target_dir, free_name(target_dir, name))
                elif os.path.exists(target):
                    if conflict == "skip":
                        job["itemsDone"] += 1
                        continue
                    if conflict == "rename":
                        target = os.path.join(target_dir, free_name(target_dir, name))
                    elif os.path.isdir(target):
                        shutil.rmtree(target)
                    else:
                        os.remove(target)
                size = tree_size(src)[0]
                if move:
                    shutil.move(src, target)
                elif os.path.isdir(src):
                    shutil.copytree(src, target)
                else:
                    shutil.copy2(src, target)
                job["bytesDone"] += size
            except Exception as e:  # noqa: BLE001
                job["failed"].append({"path": p, "error": str(e)})
            job["itemsDone"] += 1
        job["current"] = ""
        job["state"] = "done"
    except HTTPError as e:
        job["state"] = "failed"
        job["message"] = e.message


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        if ARGS.verbose:
            super().log_message(fmt, *a)

    def send_json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def body_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            return json.loads(raw or b"{}")
        except ValueError:
            raise HTTPError(400, "Bad JSON.")

    def handle_any(self):
        url = urlsplit(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query, keep_blank_values=True).items()}
        code = self.headers.get("X-Connect-Code") or q.get("code")
        if self.command == "POST" and url.path != "/api/upload":
            body = self.body_json()
        else:
            body = {}
        try:
            if code != ARGS.code:
                raise HTTPError(401, "Wrong code.")
            if ARGS.delay and url.path == "/api/list":
                time.sleep(ARGS.delay)
            route = getattr(self, "api_" + url.path[len("/api/"):].replace("/", "_"), None) if url.path.startswith("/api/") else None
            if route is None:
                raise HTTPError(404, "No such endpoint.")
            route(q, body)
        except HTTPError as e:
            if url.path in ("/api/upload", "/api/upload/chunk"):
                self.drain()
            self.send_json(e.status, {"error": e.message})
        except FileNotFoundError:
            self.send_json(404, {"error": "It's gone."})

    def drain(self):
        n = int(self.headers.get("Content-Length") or 0)
        while n > 0:
            chunk = self.rfile.read(min(n, 65536))
            if not chunk:
                break
            n -= len(chunk)

    do_GET = do_POST = do_HEAD = do_PUT = handle_any

    def send_bytes(self, data, ctype):
        """Serve an in-memory file with Range support."""
        size = len(data)
        start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            a, _, z = rng[6:].split(",")[0].partition("-")
            if a == "":
                start = max(0, size - int(z))
            else:
                start = int(a)
                if z:
                    end = min(int(z), size - 1)
            status = 206
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(data[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass

    # Existing endpoints
    def api_info(self, q, b):
        self.send_json(200, {"name": "Fake laptop", "app": "Explorer Native", "version": 1, "apiVersion": ARGS.api})

    def api_drives(self, q, b):
        usage = shutil.disk_usage(ROOT)
        self.send_json(200, [
            {"name": "T:\\", "label": "Test", "kind": "Fixed", "size": usage.total, "free": usage.free,
             "used": usage.total - usage.free},
            {"name": "G:\\", "label": "Google Drive", "kind": "Fixed", "size": 0, "free": 0, "used": 0, "unlimited": True},
        ])

    def api_list(self, q, b):
        p = local(q.get("path", ""))
        if not os.path.isdir(p):
            raise HTTPError(404, "Can't read that folder.")
        folders, files = [], []
        for name in os.listdir(p):
            full = os.path.join(p, name)
            st = os.stat(full)
            is_dir = os.path.isdir(full)
            item = {"name": name, "folder": is_dir, "size": 0 if is_dir else st.st_size, "modified": iso(st.st_mtime)}
            (folders if is_dir else files).append(item)
        key = lambda e: e["name"].lower()
        self.send_json(200, sorted(folders, key=key) + sorted(files, key=key))

    def api_file(self, q, b):
        p = local(q.get("path", ""))
        if not os.path.isfile(p):
            raise HTTPError(404, "No such file.")
        size = os.path.getsize(p)
        ext = os.path.splitext(p)[1].lower()
        ctype = {".flac": "audio/flac", ".mp3": "audio/mpeg", ".ogg": "audio/ogg", ".opus": "audio/ogg",
                 ".txt": "text/plain; charset=utf-8", ".m4a": "audio/mp4", ".wav": "audio/wav"}.get(ext, "application/octet-stream")
        start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            a, _, z = rng[6:].split(",")[0].partition("-")
            if a == "":
                start = max(0, size - int(z))
            else:
                start = int(a)
                if z:
                    end = min(int(z), size - 1)
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(p, "rb") as f:
            f.seek(start)
            left = end - start + 1
            while left > 0:
                chunk = f.read(min(left, 65536))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                left -= len(chunk)

    # Formats and decoded audio (v2.1)
    def api_formats(self, q, b):
        self.send_json(200, {"audio": AUDIO, "native": NATIVE})

    def api_audio(self, q, b):
        p = local(q.get("path", ""))
        if not os.path.isfile(p):
            raise HTTPError(404, "No such file.")
        if "broken" in os.path.basename(p):
            raise HTTPError(500, "Can't decode that file.")
        if "wav" not in WAV_CACHE:
            WAV_CACHE["wav"] = make_wav(8.0)
        self.send_bytes(WAV_CACHE["wav"], "audio/wav")

    # Resumable uploads (v2.1)
    def api_upload_start(self, q, b):
        folder = b.get("folder", "")
        local(folder)
        name = b.get("name", "")
        if not name or "\\" in name or "/" in name:
            raise HTTPError(400, "That name isn't allowed.")
        uid = uuid.uuid4().hex[:12]
        UPLOADS[uid] = {"folder": folder, "name": name, "size": int(b.get("size", 0)), "conflict": b.get("conflict", "rename")}
        open(os.path.join(PARTIALS, uid), "wb").close()
        self.send_json(200, {"ok": True, "id": uid})

    def api_upload_chunk(self, q, b):
        uid = q.get("id", "")
        if uid not in UPLOADS:
            raise HTTPError(404, "No such upload.")
        part = os.path.join(PARTIALS, uid)
        received = os.path.getsize(part)
        offset = int(q.get("offset", "0"))
        if offset != received:
            self.drain()
            self.send_json(409, {"error": "Offset mismatch.", "received": received})
            return
        n = int(self.headers.get("Content-Length") or 0)
        with open(part, "ab") as f:
            while n > 0:
                chunk = self.rfile.read(min(n, 65536))
                if not chunk:
                    break
                f.write(chunk)
                n -= len(chunk)
        if ARGS.chunk_delay:
            time.sleep(ARGS.chunk_delay)
        self.send_json(200, {"ok": True, "received": os.path.getsize(part)})

    def api_upload_status(self, q, b):
        uid = q.get("id", "")
        if uid not in UPLOADS:
            raise HTTPError(404, "No such upload.")
        self.send_json(200, {"received": os.path.getsize(os.path.join(PARTIALS, uid)), "size": UPLOADS[uid]["size"]})

    def api_upload_cancel(self, q, b):
        uid = b.get("id", "")
        UPLOADS.pop(uid, None)
        try:
            os.remove(os.path.join(PARTIALS, uid))
        except OSError:
            pass
        self.send_json(200, {"ok": True})

    def api_upload_finish(self, q, b):
        uid = b.get("id", "")
        up = UPLOADS.get(uid)
        if not up:
            raise HTTPError(404, "No such upload.")
        part = os.path.join(PARTIALS, uid)
        if os.path.getsize(part) != up["size"]:
            raise HTTPError(400, "The upload isn't complete.")
        folder = local(up["folder"])
        target = os.path.join(folder, up["name"])
        if os.path.exists(target):
            if up["conflict"] == "skip":
                os.remove(part)
                UPLOADS.pop(uid, None)
                self.send_json(200, {"ok": True, "path": remote(target)})
                return
            if up["conflict"] == "rename":
                target = os.path.join(folder, free_name(folder, up["name"]))
        UPLOADS.pop(uid, None)
        if up["folder"].lower().startswith("t:\\drive"):
            job = {"id": uuid.uuid4().hex[:8], "kind": "upload", "state": "running", "items": 1, "itemsDone": 0,
                   "bytes": up["size"], "bytesDone": 0, "current": up["name"], "message": "", "failed": [], "cancel": False}
            JOBS[job["id"]] = job

            def to_drive():
                for i in range(1, 6):
                    time.sleep(0.4)
                    job["bytesDone"] = up["size"] * i // 5
                shutil.move(part, target)
                job["itemsDone"] = 1
                job["state"] = "done"
            threading.Thread(target=to_drive, daemon=True).start()
            self.send_json(202, {"ok": True, "job": job["id"]})
            return
        shutil.move(part, target)
        self.send_json(200, {"ok": True, "path": remote(target)})

    # Sizes and details
    def api_size(self, q, b):
        path = q.get("path", "")
        p = local(path)
        if not os.path.exists(p):
            raise HTTPError(404, "Gone.")
        bytes_, files, folders = tree_size(p)
        self.send_json(200, {"path": path, "bytes": bytes_, "files": files, "folders": folders, "complete": True})

    def api_stat(self, q, b):
        path = q.get("path", "")
        p = local(path)
        st = os.stat(p)
        out = {"path": path, "name": os.path.basename(p) or path, "folder": os.path.isdir(p),
               "size": 0 if os.path.isdir(p) else st.st_size, "modified": iso(st.st_mtime), "created": iso(st.st_ctime),
               "readOnly": False, "onDrive": False}
        if p.lower().endswith(".flac"):
            out["tags"] = {"title": "Test Tone", "artist": "Fake Server", "album": "Fixtures", "year": 2026, "track": 1,
                           "durationSeconds": 20.0}
        self.send_json(200, out)

    # File actions
    def api_rename(self, q, b):
        p = local(b.get("path", ""))
        new = b.get("newName", "")
        if not new or "\\" in new or "/" in new:
            raise HTTPError(400, "That name isn't allowed.")
        if not os.path.exists(p):
            raise HTTPError(404, "Gone.")
        target = os.path.join(os.path.dirname(p), new)
        if os.path.exists(target) and target.lower() != p.lower():
            raise HTTPError(409, "That name is taken.")
        os.rename(p, target)
        self.send_json(200, {"ok": True, "path": remote(target)})

    def api_delete(self, q, b):
        deleted, failed = 0, []
        for path in b.get("paths", []):
            try:
                p = local(path)
                if os.path.isdir(p):
                    shutil.rmtree(p)
                elif os.path.exists(p):
                    os.remove(p)
                else:
                    raise HTTPError(404, "Gone.")
                deleted += 1
            except HTTPError as e:
                failed.append({"path": path, "error": e.message})
        self.send_json(200, {"ok": True, "deleted": deleted, "failed": failed})

    def api_mkdir(self, q, b):
        parent = local(b.get("parent", ""))
        name = b.get("name", "")
        if not name or "\\" in name or "/" in name:
            raise HTTPError(400, "That name isn't allowed.")
        target = os.path.join(parent, name)
        if os.path.exists(target):
            raise HTTPError(409, "That name is taken.")
        os.makedirs(target)
        self.send_json(200, {"ok": True, "path": remote(target)})

    def start_job(self, b, move):
        paths = b.get("paths", [])
        dest = b.get("destination", "")
        local(dest)
        job = {"id": uuid.uuid4().hex[:8], "kind": "move" if move else "copy", "state": "running", "items": len(paths),
               "itemsDone": 0, "bytes": 0, "bytesDone": 0, "current": "", "message": "", "failed": [], "cancel": False}
        with LOCK:
            JOBS[job["id"]] = job
        threading.Thread(target=run_job, args=(job, paths, dest, b.get("conflict", "rename"), move), daemon=True).start()
        self.send_json(202, {"ok": True, "job": job["id"]})

    def api_copy(self, q, b):
        self.start_job(b, False)

    def api_move(self, q, b):
        self.start_job(b, True)

    def api_job(self, q, b):
        job = JOBS.get(q.get("id", ""))
        if not job:
            raise HTTPError(404, "No such job.")
        self.send_json(200, {k: v for k, v in job.items() if k != "cancel"})

    def api_job_cancel(self, q, b):
        job = JOBS.get(b.get("id", ""))
        if not job:
            raise HTTPError(404, "No such job.")
        job["cancel"] = True
        self.send_json(200, {"ok": True})

    def api_upload(self, q, b):
        folder = local(q.get("folder", ""))
        name = q.get("name", "")
        conflict = q.get("conflict", "rename")
        if not name or "\\" in name or "/" in name:
            raise HTTPError(400, "That name isn't allowed.")
        target = os.path.join(folder, name)
        if os.path.exists(target):
            if conflict == "skip":
                self.drain()
                self.send_json(200, {"ok": True, "path": remote(target)})
                return
            if conflict == "rename":
                target = os.path.join(folder, free_name(folder, name))
        n = int(self.headers.get("Content-Length") or 0)
        with open(target, "wb") as f:
            while n > 0:
                chunk = self.rfile.read(min(n, 65536))
                if not chunk:
                    break
                f.write(chunk)
                n -= len(chunk)
        self.send_json(200, {"ok": True, "path": remote(target)})


def make_wav(seconds, rate=44100):
    """24-bit stereo PCM sine, the shape /api/audio sends."""
    frames = int(seconds * rate)
    out = bytearray()
    for i in range(frames):
        v = int(0.3 * 8388607 * math.sin(2 * math.pi * 330 * i / rate))
        s = struct.pack("<i", v)[:3]
        out += s + s
    data_len = len(out)
    header = b"RIFF" + struct.pack("<I", 36 + data_len) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * 6, 6, 24)
    header += b"data" + struct.pack("<I", data_len)
    return bytes(header + out)


WAV_CACHE = {}


def main():
    global ARGS, ROOT
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=47810)
    ap.add_argument("--code", default="12345678")
    ap.add_argument("--root")
    ap.add_argument("--api", type=int, default=2)
    ap.add_argument("--delay", type=float, default=0, help="seconds to stall every listing")
    ap.add_argument("--chunk-delay", type=float, default=0, help="seconds to stall after each upload chunk")
    ap.add_argument("--verbose", action="store_true")
    ARGS = ap.parse_args()
    ROOT = ARGS.root or tempfile.mkdtemp(prefix="fakeroot")
    os.makedirs(ROOT, exist_ok=True)
    seed(ROOT)
    print(f"fake server on {ARGS.port}, root {ROOT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", ARGS.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
