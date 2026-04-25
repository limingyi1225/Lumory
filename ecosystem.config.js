// Requires: pm2 install pm2-logrotate (on host)
// PM2 ecosystem config. Usage: `pm2 start ecosystem.config.js`
module.exports = {
  apps: [
    {
      // Name must match the running process on the production server (/root/server).
      name: 'lumory-server',
      script: './server/index.js',
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
      // Log rotation — picked up by pm2-logrotate module on host.
      max_size: '10M',
      retain: 10,
      compress: true,
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
