#!/usr/bin/env bash
# Live scenarios for Claude worker tool exclusions. Args: <worktree>
set -u
WT=$1
EV=/home/doug/.no-mistakes/evidence/01M6RHZ2KQ2RTDS70P9CVA0JXZ
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-excl-live.XXXXXX")
. "$WT/bin/fm-exclude-tools-lib.sh"
mkdir -p "$T/cfg"
printf '%s\n' 'Workflow' 'mcp__srv' > "$T/cfg/crew-exclude-tools"
echo "== A: runtime refusal (real fm_exclude_tools_check, non-empty list) =="
for h in claude codex grok pi; do
  err=$(fm_exclude_tools_check "$h" 0 "$T/cfg" 2>&1); rc=$?
  echo "harness=$h rc=$rc ${err:-<no error>}"
done
echo "raw launch:"; err=$(fm_exclude_tools_check claude 1 "$T/cfg" 2>&1); echo "rc=$? $err"
echo "== B: real claude, launch shape, prompt must survive variadic flag =="
cat > "$T/cap.py" <<'PY'
import http.server, sys
pf, cf = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("content-length", 0)))
        if "/v1/messages" in self.path and "count_tokens" not in self.path:
            open(cf, "ab").write(b.replace(b"\n", b" ") + b"\n")
        r = b'{"type":"error","error":{"type":"overloaded_error","message":"capture only"}}'
        self.send_response(529); self.send_header("content-type","application/json")
        self.send_header("content-length", str(len(r))); self.end_headers(); self.wfile.write(r)
    do_GET = do_POST
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(pf, "w").write(str(s.server_address[1])); s.serve_forever()
PY
run_arm() { # label, extra args...
  local label=$1; shift
  rm -f "$T/$label.port" "$T/$label.jsonl"
  python3 -I "$T/cap.py" "$T/$label.port" "$T/$label.jsonl" & local pid=$!
  for _ in $(seq 1 50); do [ -s "$T/$label.port" ] && break; sleep 0.1; done
  local port; port=$(cat "$T/$label.port")
  ( cd "$T" && ANTHROPIC_BASE_URL="http://127.0.0.1:$port" timeout 60 claude "$@" >/dev/null 2>&1 ) || true
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  python3 -I - "$T/$label.jsonl" "$label" <<'PY'
import json, sys
best = None
for line in open(sys.argv[1]):
    try: req = json.loads(line)
    except ValueError: continue
    if best is None or len(req.get("tools", [])) > len(best.get("tools", [])): best = req
if best is None: print(sys.argv[2], "NO REQUEST"); sys.exit(0)
names = [t["name"] for t in best["tools"]]
size = len(json.dumps(best["tools"], separators=(",", ":")))
text = json.dumps(best["messages"])
print(f"{sys.argv[2]}: tools={len(names)} tools_json_bytes={size} workflow_present={'Workflow' in names} prompt_survived={'PROMPT-SENTINEL-7Q' in text}")
PY
}
run_arm baseline -p "PROMPT-SENTINEL-7Q say hi" --max-turns 1
run_arm excluded -p "PROMPT-SENTINEL-7Q say hi" --max-turns 1 --disallowedTools 'Workflow,mcp__srv' --append-system-prompt 'sys-x'
rm -rf "$T"
