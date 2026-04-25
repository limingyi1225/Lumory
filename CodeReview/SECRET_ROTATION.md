# appSharedSecret 轮换 — 部署清单（v2）
**日期**: 2026-04-24  
**新密钥位置**: `Lumory.local.xcconfig`（本机 gitignored 文件）+ 生产服务器 `/root/server/.env` —— 不在本文件，不在 git。

## 背景
第一版 reviewer 核实：上一版 `appSharedSecret` 的哈希值与公开 PR1 历史完全一致——从来没真正轮换过。  
第二版 reviewer 又指出：把新 secret 硬编码到 `AppSecrets.swift` 的 fallback 字面量里，提交公开仓库后同样泄漏 → 等于没轮换。

**最终方案**（v2，已实施）：secret 只存在两处 —— `Lumory.local.xcconfig`（本机）和生产 `/root/server/.env`。源码和 git 都没有。

## 已完成（两侧都完成）
- ✅ `openssl rand -base64 48` 生成新值
- ✅ `Lumory.local.xcconfig`（gitignored）创建，真实值写入此文件
- ✅ `Lumory.xcconfig` 通过 `#include?` 拉入 local.xcconfig 值 → `INFOPLIST_KEY_APP_SHARED_SECRET` → Info.plist
- ✅ `AppSecrets.swift` 的 fallback 改成**空字符串**（读不到 Info.plist 时直接 401，非静默硬编码）
- ✅ 生产服务器 SSH 到 `root@64.176.209.155`，`.env` 已更新，`pm2 restart lumory-server` 已执行
- ✅ 验证 401/401/400/200 四路全通过
- ✅ `.gitignore` 已覆盖 `server/.env` + `Lumory.local.xcconfig`

## 首次 clone 仓库 / 新开发机 setup
```bash
cd /path/to/Lumory
cp Lumory.local.xcconfig.sample Lumory.local.xcconfig
# 编辑 Lumory.local.xcconfig，把 APP_SHARED_SECRET = REPLACE_WITH_ROTATED_APP_SHARED_SECRET 改成从别处获取的真实值
# （secret 通过带外渠道传递：password manager / 内部 wiki / ssh + cat .env / 面对面交）
```
然后在 Xcode 里一次性挂 base config（约 30 秒）：

**Xcode → 打开 Lumory.xcodeproj → 选 Lumory project（顶层蓝图标）→ Info tab → Configurations → 把 Debug 和 Release 两行的 "Based on Configuration File" 下拉都改成 `Lumory`（即 `Lumory.xcconfig`）→ Cmd+B 重新 build**

不做这步 App 会一直 401，但本地日记、CloudKit 同步、搜索依然正常；只有 AI 功能走后端的会挂。

## 未来轮换操作（每次约 2 分钟）
1. `openssl rand -base64 48` 生成新值
2. `Lumory.local.xcconfig` 里改 `APP_SHARED_SECRET = <新值>`
3. SSH 到 `root@64.176.209.155`：
   ```bash
   cd /root/server
   sed -i 's|^APP_SHARED_SECRET=.*$|APP_SHARED_SECRET=<新值>|' .env
   pm2 restart lumory-server
   ```
4. Xcode 重新 build → 装到设备
5. 验证：
   ```bash
   # 不带 header → 401
   curl -s -o /dev/null -w "%{http_code}\n" -X POST https://lumory.isaabby.com/api/openai/embeddings \
     -H "Content-Type: application/json" -d '{"input":"t"}'
   # 带新 header + 合法 input → 200
   curl -s -o /dev/null -w "%{http_code}\n" -X POST https://lumory.isaabby.com/api/openai/embeddings \
     -H "X-App-Secret: <新值>" -H "Content-Type: application/json" -d '{"input":"t"}'
   ```

## 部署窗口
- 服务器切换 `.env` 之后，任何还在跑旧值的 iPhone app 全部 401 —— 保存日记本身不受影响（只写本地 CoreData + CloudKit），但 Ask Past / Insights AI / 粘贴导入等 AI 功能失效。
- 最平滑：先把带新值的 build 发给 TestFlight / 装到自己设备 → 确认 AI 能用 → 再 SSH 切服务器。
- 2026-04-24 本轮因为是应急轮换，我们是**先切服务器再让你出新 build** —— 这期间旧 app 的 AI 功能会断，数据不丢。
