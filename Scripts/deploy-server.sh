#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_HOST="${LUMORY_SERVER_HOST:-root@64.176.209.155}"
REMOTE_DIR="${LUMORY_SERVER_REMOTE_DIR:-/root/server}"
PUBLIC_HEALTH_URL="${LUMORY_SERVER_HEALTH_URL:-https://lumory.isaabby.com/health}"
REMOTE_PARENT="$(dirname "$REMOTE_DIR")"
REMOTE_NAME="$(basename "$REMOTE_DIR")"

cd "$ROOT_DIR"

echo "Creating remote backup..."
ssh "$REMOTE_HOST" \
  "set -e; cd '$REMOTE_PARENT'; backup_name='${REMOTE_NAME}-backup-'\$(date +%Y%m%d-%H%M%S)'.tgz'; tar -czf \"\$backup_name\" --exclude='${REMOTE_NAME}/node_modules' --exclude='${REMOTE_NAME}/logs' '$REMOTE_NAME'; echo \"backup=$REMOTE_PARENT/\$backup_name\""

echo "Syncing server files..."
COPYFILE_DISABLE=1 rsync -az \
  --exclude 'node_modules/' \
  --exclude 'logs/' \
  --exclude '.env' \
  --exclude '._*' \
  --exclude '.DS_Store' \
  server/ "$REMOTE_HOST:$REMOTE_DIR/"

echo "Syncing PM2 ecosystem config..."
COPYFILE_DISABLE=1 rsync -az ecosystem.config.js "$REMOTE_HOST:$REMOTE_DIR/ecosystem.config.js"

echo "Installing, testing, and restarting..."
ssh "$REMOTE_HOST" \
  "set -e; cd '$REMOTE_DIR'; find . -name '._*' -type f -delete; npm ci; npm run lint; npm test; current_mode=\$(pm2 jlist | node -e 'let s=\"\"; process.stdin.on(\"data\", d => s += d); process.stdin.on(\"end\", () => { const app = JSON.parse(s).find(a => a.name === \"lumory-server\"); process.stdout.write(app?.pm2_env?.exec_mode || \"missing\"); });'); if [ \"\$current_mode\" = \"missing\" ]; then pm2 start ecosystem.config.js --only lumory-server --update-env; elif [ \"\$current_mode\" != \"fork_mode\" ]; then pm2 delete lumory-server; pm2 start ecosystem.config.js --only lumory-server --update-env; else pm2 startOrReload ecosystem.config.js --only lumory-server --update-env; fi; pm2 save; sleep 2; pm2 jlist | node -e 'let s=\"\"; process.stdin.on(\"data\", d => s += d); process.stdin.on(\"end\", () => { const app = JSON.parse(s).find(a => a.name === \"lumory-server\"); if (!app || app.pm2_env.status !== \"online\" || app.pm2_env.exec_mode !== \"fork_mode\") process.exit(1); console.log(\"pm2=\" + app.name + \":\" + app.pm2_env.status + \":\" + app.pm2_env.exec_mode); });'; curl -fsS http://127.0.0.1:3000/health"

echo
echo "Checking public health..."
curl -fsS "$PUBLIC_HEALTH_URL"
echo
