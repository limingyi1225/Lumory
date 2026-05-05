#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="${LUMORY_SERVER_HOST:-root@64.176.209.155}"
PUBLIC_HEALTH_URL="${LUMORY_SERVER_HEALTH_URL:-https://lumory.isaabby.com/health}"
REMOTE_DIR="${LUMORY_SERVER_REMOTE_DIR:-/root/server}"
REMOTE=1

if [[ "${1:-}" == "--public-only" ]]; then
  REMOTE=0
fi

echo "== Public health =="
curl -fsS --max-time 10 "$PUBLIC_HEALTH_URL"
echo

if [[ "$REMOTE" -eq 0 ]]; then
  exit 0
fi

echo "== Remote host =="
ssh "$REMOTE_HOST" "set -e
echo KERNEL=\$(uname -r)
uptime -p
echo
echo '== Disk =='
df -h /
journalctl --disk-usage
echo
echo '== Services =='
systemctl --failed --no-pager || true
echo nginx=\$(systemctl is-active nginx || true)
echo pm2-root=\$(systemctl is-active pm2-root || true)
echo
echo '== PM2 =='
pm2 list
echo
echo '== Lumory PM2 config =='
pm2 jlist | REMOTE_DIR='$REMOTE_DIR' node -e 'let s=\"\"; process.stdin.on(\"data\", d => s += d); process.stdin.on(\"end\", () => { const app = JSON.parse(s).find(a => a.name === \"lumory-server\"); if (!app) process.exit(1); const env = app.pm2_env; const expectedDir = process.env.REMOTE_DIR; console.log(\"name=\" + app.name); console.log(\"status=\" + env.status); console.log(\"exec_mode=\" + env.exec_mode); console.log(\"cwd=\" + env.pm_cwd); console.log(\"script=\" + env.pm_exec_path); if (env.status !== \"online\" || env.exec_mode !== \"fork_mode\" || env.pm_cwd !== expectedDir || env.pm_exec_path !== expectedDir + \"/index.js\") process.exit(1); })'
echo
echo '== Local health =='
curl -fsS --max-time 5 http://127.0.0.1:3000/health
echo
echo
echo '== Server version smoke =='
cd '$REMOTE_DIR'
node -e 'const { sseFrameHasDone } = require(\"./index\"); if (sseFrameHasDone(\"data: {\\\"x\\\":\\\"data: [DONE]\\\"}\")) process.exit(1); console.log(\"deployed_sse_check=ok\")'
"
