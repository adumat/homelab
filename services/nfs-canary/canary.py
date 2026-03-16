#!/usr/bin/env python3
"""NFS canary - userspace NFS client via libnfs to detect export issues.

Uses libnfs (ctypes) to maintain persistent NFS connections to each export
and periodically stat the root directory. Unlike kernel mounts, a stale
libnfs connection never blocks the pod or kubelet — the canary stays alive
and keeps reporting metrics even when NFS is unhealthy.
"""

import ctypes
import http.server
import os
import threading
import time

NFS_SERVER = os.environ.get("NFS_SERVER", "elizabeth.lan")
NFS_EXPORTS = [e.strip() for e in os.environ.get("NFS_EXPORTS", "").split(",") if e.strip()]
EXPORT_LABELS = [l.strip() for l in os.environ.get("EXPORT_LABELS", "").split(",") if l.strip()]
MOUNT_PATHS = [p.strip() for p in os.environ.get("MOUNT_PATHS", "").split(",") if p.strip()]
CHECK_INTERVAL = int(os.environ.get("CHECK_INTERVAL", "15"))
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9999"))
PROBE_TIMEOUT = int(os.environ.get("PROBE_TIMEOUT", "5"))

# --- libnfs ctypes bindings ---

_lib = ctypes.CDLL("libnfs.so.14")

_lib.nfs_init_context.restype = ctypes.c_void_p
_lib.nfs_init_context.argtypes = []

_lib.nfs_mount.restype = ctypes.c_int
_lib.nfs_mount.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]

_lib.nfs_stat64.restype = ctypes.c_int
_lib.nfs_stat64.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p]

_lib.nfs_destroy_context.restype = None
_lib.nfs_destroy_context.argtypes = [ctypes.c_void_p]

_lib.nfs_get_error.restype = ctypes.c_char_p
_lib.nfs_get_error.argtypes = [ctypes.c_void_p]

# nfs_stat_64 has 15 uint64 fields — 120 bytes; pad to 256 for safety
_STAT_BUF_SIZE = 256


def nfs_connect(server, export):
    """Create a libnfs context and mount the export. Returns ctx or None."""
    ctx = _lib.nfs_init_context()
    if not ctx:
        return None
    ret = _lib.nfs_mount(ctx, server.encode(), export.encode())
    if ret != 0:
        err = _lib.nfs_get_error(ctx)
        print("  mount %s:%s failed: %s" % (server, export, err.decode() if err else "unknown"), flush=True)
        _lib.nfs_destroy_context(ctx)
        return None
    return ctx


def nfs_check(ctx):
    """Stat the root directory on an existing context. Returns True if healthy."""
    buf = ctypes.create_string_buffer(_STAT_BUF_SIZE)
    ret = _lib.nfs_stat64(ctx, b"/", buf)
    return ret == 0


def nfs_disconnect(ctx):
    """Destroy a libnfs context."""
    if ctx:
        _lib.nfs_destroy_context(ctx)


# --- State management ---

# Each export: { "ctx": void_p|None, "healthy": bool }
_contexts = {}
# Snapshot dict replaced atomically for metrics handler
_state = {}


def init_contexts():
    """Connect to all exports at startup."""
    global _state
    new_state = {}
    for export, label, mount in zip(NFS_EXPORTS, EXPORT_LABELS, MOUNT_PATHS):
        print("Connecting to %s:%s ..." % (NFS_SERVER, export), flush=True)
        ctx = nfs_connect(NFS_SERVER, export)
        healthy = False
        if ctx:
            healthy = nfs_check(ctx)
            if healthy:
                print("  %s: OK" % label, flush=True)
            else:
                print("  %s: connected but stat failed" % label, flush=True)
                nfs_disconnect(ctx)
                ctx = None
        else:
            print("  %s: FAILED" % label, flush=True)
        _contexts[export] = {"ctx": ctx, "healthy": healthy}
        new_state[export] = healthy
    _state = new_state


def _check_with_timeout(export, timeout):
    """Run nfs_stat64 in a thread with a timeout. Returns True if healthy."""
    result = [False]

    def _do_check():
        ctx = _contexts[export]["ctx"]
        if ctx:
            result[0] = nfs_check(ctx)

    t = threading.Thread(target=_do_check, daemon=True)
    t.start()
    t.join(timeout=timeout)
    if t.is_alive():
        # Timed out — connection is stuck
        return False
    return result[0]


def check_loop():
    """Periodically check all NFS exports via libnfs."""
    global _state
    while True:
        time.sleep(CHECK_INTERVAL)
        new_state = {}
        for export, label, mount in zip(NFS_EXPORTS, EXPORT_LABELS, MOUNT_PATHS):
            info = _contexts[export]
            if info["ctx"] is None:
                # Try to reconnect
                ctx = nfs_connect(NFS_SERVER, export)
                if ctx and nfs_check(ctx):
                    _contexts[export] = {"ctx": ctx, "healthy": True}
                    new_state[export] = True
                    print("Reconnected: %s" % label, flush=True)
                else:
                    if ctx:
                        nfs_disconnect(ctx)
                    _contexts[export] = {"ctx": None, "healthy": False}
                    new_state[export] = False
                continue

            healthy = _check_with_timeout(export, PROBE_TIMEOUT)
            if healthy:
                _contexts[export]["healthy"] = True
                new_state[export] = True
            else:
                # Connection is stale/broken — tear down and mark unhealthy
                print("Unhealthy: %s (destroying context)" % label, flush=True)
                nfs_disconnect(info["ctx"])
                _contexts[export] = {"ctx": None, "healthy": False}
                new_state[export] = False
        _state = new_state


# --- HTTP metrics ---

class MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        snapshot = _state
        lines = []
        overall = 1
        for export, mount, label in zip(NFS_EXPORTS, MOUNT_PATHS, EXPORT_LABELS):
            val = 1 if snapshot.get(export, False) else 0
            lines.append(
                'nfs_canary_health{mount="%s",export="%s"} %d' % (mount, label, val)
            )
            if val == 0:
                overall = 0
        lines.append("nfs_canary_health_overall %d" % overall)
        body = "\n".join(lines) + "\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    assert len(NFS_EXPORTS) == len(EXPORT_LABELS) == len(MOUNT_PATHS), (
        "NFS_EXPORTS, EXPORT_LABELS, and MOUNT_PATHS must have equal length"
    )
    init_contexts()
    threading.Thread(target=check_loop, daemon=True).start()
    print("NFS canary listening on :%d" % LISTEN_PORT, flush=True)
    print("Monitoring: %s" % ", ".join(EXPORT_LABELS), flush=True)
    http.server.HTTPServer(("", LISTEN_PORT), MetricsHandler).serve_forever()
