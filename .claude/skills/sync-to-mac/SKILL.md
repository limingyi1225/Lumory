---
name: sync-to-mac
description: Lumory 双 Mac 协作 git 同步流水线。默认 main 直推直拉(用户实际工作流);dev 分支作为可选 wip 中转,只在用户明确要求时才用。三个动作 push / pull / ship。用户说"推上去 / push / 同步过去"、"拉一下 / pull / 同步过来"、"合到 main / ship / 上 main"触发。
---

# 双机同步流水线

Lumory 用户在两台 Mac 交替开发。**实际工作流是直接在 main 上 commit + push / pull**,不走 dev 中转。dev 分支只在用户明确说"push wip / 走 dev"时才用。

## 心智模型(默认 main)

```
A 电脑  --commit--push-->   origin/main   <--pull--commit-->  B 电脑
                       (默认就在 main 上交替工作)
```

可选 wip 中转(用户主动要求时):

```
A 电脑  --push wip-->  origin/dev  <--pull--   B 电脑
                          |
                          | (一段做完了,用户说 ship)
                          v
                       squash-merge 到 main
```

## 三个动作

### 1. 推上去(push)— 用户:"推一下 / push / 同步过去"

**默认推到 main**(不是 dev)。

```
git status                               # 给用户看一眼会带啥
# 默认在 main:
git add -A
git commit -m "<用户给的 message>"        # 必须问用户,不允许默认 wip
git pull --rebase                        # 防止对面机器先动过 main
git push
```

**强制问 commit message**(因为是直推 main,跟历史 commit 风格一致 — 沿用仓库中英混合风格,参考 `git log`)。**禁止**默认 "wip" 或猜测。

工作树干净时直接告知"没改动",别空提交。

**例外:用户明确说"push wip / push 到 dev / 走 dev"**:走 dev 流程:
```
git checkout dev 2>/dev/null || git checkout -b dev
git push -u origin dev                   # 首次
git add -A
git commit -m "wip"                      # 此时默认 wip OK
git push
git checkout main                        # 推完切回 main
```

### 2. 拉下来(pull)— 用户:"拉一下 / pull / 同步过来"

```
git fetch origin
git status                               # 检查本地有没有未提交改动
git branch --show-current
```

- **默认拉 main**:
  - 在 main + 干净 → `git pull`
  - 不在 main + 干净 → `git checkout main && git pull`
- **本地有未提交改动 → 停下来问用户**:stash / 先 commit 再 push / 还是放弃。**绝不**自己决定。
- **dev 跟 main 分叉**(对面机器在 main 上动过):**只管 main 那侧,dev 不动**。如果用户没明说处理 dev,默认就忽略 dev 的状态,等用户主动管。

拉完显示 `git log --oneline -5` 让用户看新增了啥。

### 3. 合到 main(ship)— 用户:"ship / 合到 main / 上 main"

**仅当用户用了 dev 中转**才需要这个动作。如果一直在 main 直推,push 就已经 ship 了,不存在单独的 ship 步骤。

谨慎流程,**强制人工确认 commit message**。

1. 展示 dev 比 main 多的内容:
   ```
   git log main..dev --oneline
   git diff main...dev --stat
   ```
2. **问用户语义化 commit message**(`feat: xxx` / `fix: xxx` / `chore: xxx`)。**禁止**默认 "wip" 或猜测。
3. 用户确认后:
   ```
   git checkout main
   git pull                              # 防止 main 被对面机器先动过
   git merge --squash dev
   git commit -m "<用户给的 message>

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
   git push
   ```
4. 把 dev **重置**对齐 main(不是 merge!),清掉已经 squash 过的 wip 痕迹:
   ```
   git checkout dev
   git reset --hard origin/main
   git push --force-with-lease
   git checkout main                     # 默认留在 main
   ```

   **为什么 reset 不 merge**:dev 上的 wip commit 已经被 squash 进 main 一条新 SHA 的 commit。
   `git merge main` 会因为 tree 相同只加个空 merge commit,导致 dev 永远比 main 多两条 dangling
   commit。reset 直接对齐,dev 重新当干净的 wip 中转站。
   `--force-with-lease` 是安全的 force-push:只覆盖你最后看到的状态,对面机器偷偷动过 dev
   会被拒绝。dev 是个人 wip 分支,这个 trade-off 合理。

## 安全规则

- **绝不** `git push --force` 到 main。dev 上 ship 后的对齐 reset **可以**用 `--force-with-lease`(不是裸 `--force`)。
- **绝不**自动决定 stash:本地有未提交改动遇到 pull / push,**停下来问**
- **绝不**在 push 到 main 或 ship 时用"wip" / 自动生成的语义 message:必须问用户
- **绝不**删 dev 分支(虽然不常用,留着备用)
- 拉完 / 推完 / ship 完都跑一次 `git status` 确认状态

## 首次设置(用户从未跑过这个 skill 时)

默认 main 工作流不需要 setup,直接用。

如果用户要 dev 中转:
```
git checkout -b dev                      # 从当前 HEAD 拉 dev
git push -u origin dev
```

## 不该这个 skill 干的事

- **冲突解决**:遇到 merge conflict 把现状报告给用户,让用户决定。skill 不自动选择 ours/theirs。
- **rebase / cherry-pick**:超出本 skill 范围(除 `git pull --rebase` 这种例行操作),用户要这个让他们手动来。

## 常见坑

- **A 推完 B 没拉就开始改** → B 推时会被 reject(non-fast-forward)。`git pull --rebase` 在 push 前自动做了,正常不会撞;真撞了让用户决定。
- **dev / main 历史分叉**(用户上次在另一台机器 ship 过没 reset dev)→ 默认不动 dev,只管 main。除非用户明说要清理 dev。
- **第一次在新电脑上跑** → main 已经默认存在,直接 `git fetch && git pull` 即可。
