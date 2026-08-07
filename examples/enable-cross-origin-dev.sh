#!/usr/bin/env bash
# enable-cross-origin-dev.sh — opt-in patch that lets a standalone
# cross-origin frontend (e.g. a client that can point at ANY bench URL at
# runtime, not just same-origin apps) talk to a disposable bench: both its
# REST API (CORS) and its socket.io realtime channel.
#
# WHY THIS EXISTS
# ----------------
# Frappe assumes same-origin deployment in three separate places. A
# same-origin app (its own frontend served from the same host as its
# backend) never hits any of these; a standalone client dev-served from a
# different origin (e.g. Vite on localhost:5173 pointed at a bench on
# some-site.local:8xxx) hits all three:
#
#   1. REST CORS: disabled by default (no `allow_cors` in site config) ->
#      every cross-origin fetch fails preflight.
#   2. Socket.io "Invalid origin": apps/frappe/realtime/middlewares/
#      authenticate.js rejects any connection whose Host header and Origin
#      header resolve to different hostnames, before it even checks auth.
#   3. Socket.io "Invalid namespace" / "Unauthorized": that same file's
#      get_site_name() falls back to deriving the socket NAMESPACE from
#      Origin whenever Host isn't localhost/127.0.0.1 (wrong site ->
#      namespace mismatch), and realtime/utils.js's get_url() builds its
#      internal auth-validation URL from Origin's hostname too (hits
#      nothing, since nothing is listening on the frontend's own origin at
#      the bench's webserver port).
#
# This script patches around all three, but ONLY when the client explicitly
# opts in (sends an `X-Frappe-Site-Name` header, or the bench operator sets
# a config flag) — same-origin traffic on the same bench is completely
# unaffected either way. See the frontend-side half of this pattern (an
# `X-Frappe-Site-Name` header + polling-before-websocket transport order)
# in pwa_poc's src/utils/socket.ts, or replicate it in any other standalone
# client.
#
# WHEN TO USE
# -----------
# Only on a disposable/multihand dev bench you fully control, never on a
# shared reference bench or anything production-adjacent. Idempotent: safe
# to re-run.
#
# USAGE
#   enable-cross-origin-dev.sh <bench-dir> <allowed-origin> [webserver-port]
#   e.g. enable-cross-origin-dev.sh /workspace/development/my-bench http://localhost:5173

set -euo pipefail

BENCH_DIR="${1:?Usage: $0 <bench-dir> <allowed-origin> [webserver-port]}"
ALLOWED_ORIGIN="${2:?Usage: $0 <bench-dir> <allowed-origin> [webserver-port]}"

if [[ ! -d "${BENCH_DIR}/sites" ]] || [[ ! -d "${BENCH_DIR}/apps/frappe" ]]; then
	echo "error: ${BENCH_DIR} doesn't look like a bench root (no sites/ or apps/frappe/)" >&2
	exit 1
fi

AUTH_JS="${BENCH_DIR}/apps/frappe/realtime/middlewares/authenticate.js"
UTILS_JS="${BENCH_DIR}/apps/frappe/realtime/utils.js"

# ---- 1. REST CORS ----
cd "${BENCH_DIR}"
bench set-config -g allow_cors "${ALLOWED_ORIGIN}"
bench set-config -g disable_socketio_origin_check 1

# ---- 2. Origin-check bypass in authenticate.js (idempotent) ----
if ! grep -q "disable_socketio_origin_check" "${AUTH_JS}"; then
	python3 - "${AUTH_JS}" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

old = '''	if (get_hostname(socket.request.headers.host) != get_hostname(socket.request.headers.origin)) {
		next(new Error("Invalid origin"));
		return;
	}'''

new = '''	// Dev-only escape hatch (frappe-multihand enable-cross-origin-dev.sh):
	// disposable benches used by a standalone cross-origin frontend will
	// always fail this check, since Host (the target site) and Origin (the
	// frontend's own origin) legitimately differ for that topology.
	// Opt-in via common_site_config.json ("disable_socketio_origin_check":
	// 1) - never on by default, never on a production site.
	if (
		!conf.disable_socketio_origin_check &&
		get_hostname(socket.request.headers.host) != get_hostname(socket.request.headers.origin)
	) {
		next(new Error("Invalid origin"));
		return;
	}'''

assert old in content, f"anchor not found in {path} (frappe version mismatch? patch manually)"
content = content.replace(old, new)
with open(path, "w") as f:
    f.write(content)
print(f"patched {path}")
PYEOF
else
	echo "authenticate.js: origin-check bypass already present, skipping"
fi

# ---- 3. get_url() host resolution fix in utils.js (idempotent) ----
if ! grep -q "x-frappe-site-name" "${UTILS_JS}"; then
	python3 - "${UTILS_JS}" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

old = '''function get_url(socket, path) {
	if (!path) {
		path = "";
	}
	let url = socket.request.headers.origin;
	if (conf.developer_mode) {
		let [protocol, host, port] = url.split(":");
		port = conf.webserver_port;
		url = `${protocol}:${host}:${port}`;
	}
	return url + path;
}'''

new = '''function get_url(socket, path) {
	if (!path) {
		path = "";
	}
	// Dev-only (frappe-multihand enable-cross-origin-dev.sh): a standalone
	// cross-origin frontend sends X-Frappe-Site-Name because its own
	// Origin's hostname is NOT the target site's hostname (it can point at
	// any server at runtime) - build the internal auth-check URL from that
	// instead of Origin in that case. Opt-in: only kicks in when the
	// header is actually present, so same-origin traffic (which never
	// sends this header) is completely unaffected.
	let url = socket.request.headers.origin;
	const site_name_header = socket.request.headers["x-frappe-site-name"];
	if (conf.developer_mode) {
		if (site_name_header) {
			const protocol = url ? url.split(":")[0] : "http";
			url = `${protocol}://${site_name_header}:${conf.webserver_port}`;
		} else {
			let [protocol, host, port] = url.split(":");
			port = conf.webserver_port;
			url = `${protocol}:${host}:${port}`;
		}
	}
	return url + path;
}'''

assert old in content, f"anchor not found in {path} (frappe version mismatch? patch manually)"
content = content.replace(old, new)
with open(path, "w") as f:
    f.write(content)
print(f"patched {path}")
PYEOF
else
	echo "utils.js: X-Frappe-Site-Name resolution already present, skipping"
fi

cat <<EOF

Done. Restart the bench's process group to pick up both the config and the
JS patches (Node caches required modules in memory; a config-only reload is
NOT enough for the JS changes):

  Under 'bench start' + honcho: killing a single Procfile entry brings down
  the WHOLE process group, not just that one — so kill and relaunch the
  bench's honcho master itself, then run a health check before assuming
  it's back:
    pkill -f "bench start" pattern-matching this bench's cwd, or find the
    honcho master PID via its /proc/<pid>/cwd, then:
      cd ${BENCH_DIR} && nohup bench start >> logs/bench-start.out 2>&1 &

On the CLIENT side, your frontend's socket.io connection needs to:
  - send an "X-Frappe-Site-Name: <sitename>" header on connect (takes
    priority over the Origin-derived namespace/host resolution this script
    bypassed)
  - list "polling" BEFORE "websocket" in its transports option - the native
    browser WebSocket API cannot carry custom headers at all, so if it
    connects via websocket first, Authorization/X-Frappe-Site-Name never
    reach the server and every connection fails silently with "Invalid
    namespace" or "Unauthorized"
EOF
