// Requires on host:
//   pm2 install pm2-logrotate
//   pm2 set pm2-logrotate:max_size 10M
//   pm2 set pm2-logrotate:retain 10
//   pm2 set pm2-logrotate:compress true
const fs = require('fs');
const path = require('path');

const serverDirFromRepoRoot = path.join(__dirname, 'server');
const appCwd = fs.existsSync(path.join(serverDirFromRepoRoot, 'index.js'))
  ? serverDirFromRepoRoot
  : __dirname;

// PM2 ecosystem config.
// Usage from repo root: `pm2 start ecosystem.config.js`
// Usage on production host (/root/server): `pm2 start ecosystem.config.js`
module.exports = {
  apps: [
    {
      // Name must match the running process on the production server (/root/server).
      name: 'lumory-server',
      cwd: appCwd,
      script: './index.js',
      instances: 1,
      exec_mode: 'fork',
      watch: false,
      // 512M：embedding/SSE 代理 + 峰值 buffer 轻松超 256M，PM2 会在流中间重启中断 SSE。
      max_memory_restart: '512M',
      // Restart policy — give up after 10 crashes in quick succession.
      max_restarts: 10,
      min_uptime: '30s',
      // Log management — structured JSON from pino goes here, PM2 stamps each line.
      log_date_format: 'YYYY-MM-DD HH:mm:ss.SSS',
      merge_logs: true,
      out_file: './logs/backend-out.log',
      error_file: './logs/backend-err.log',
      env: {
        NODE_ENV: 'production',
        LOG_LEVEL: 'info',
      },
      env_development: {
        NODE_ENV: 'development',
        LOG_LEVEL: 'debug',
      },
    },
  ],
};
