---
name: sync-to-mac
description: Lumory 双 Mac 协作 git 同步流水线。用 dev 分支当 WIP 中转,main 只接收干净 commit。三个动作 push / pull / ship。用户说"推上去 / push wip / 同步过去"、"拉一下 / pull / 同步过来"、"合到 main / ship / 上 main / 这段能合了"触发。
---

# 双机同步流水线

Lumory 用户在两台 Mac 交替开发。直接往 main 推 WIP 会把版本号、半成品、调试代码混进 main 历史。这个 skill 用一个长期 `dev` 分支当中转。

## 心智模型

```
A 电脑    --push-->   origin/dev   <--pull--   B 电脑
             (随便提交 wip,可以脏)
                     |
                     | (一段做完了)
                     v
                  squash-merge
                     |
                     v
                  origin/main
              (只收语义干净的 commit)
```

## 三个动作

### 1. 推上去(push)— 用户:"推一下 / push / 同步过去"

把当前所有未提交改动推到 `origin/dev`。

```
git status                               # 给用户看一眼会带啥
# 若不在 dev 分支:
git checkout dev 2>/dev/null || git checkout -b dev
# 若 dev 远端不存在:
git push -u origin dev                   # 首次

git add -A
git commit -m "wip"                      # 默认 wip,用户给短消息就用用户的
git push
```

工作树干净时直接告知用户"没改动",别空提交。

### 2. 拉下来(pull)— 用户:"拉一下 / pull / 同步过来"

```
git fetch origin
git status                               # 检查本地有没有未提交改动
```

- 本地干净 + 在 dev → `git pull`
- 本地干净 + 不在 dev → `git checkout dev && git pull`
- **本地有未提交改动 → 停下来问用户**:stash / 先 push wip / 还是放弃。**绝不**自己决定。

拉完显示 `git log --oneline -5` 让用户看新增了啥。

### 3. 合到 main(ship)— 用户:"ship / 合到 main / 上 main / 这段能 ship 了"

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

   Co-Authored-By: Codex Opus 4.7 (1M context) <noreply@anthropic.com>"
   git push
   ```
4. 把 dev **重置**对齐 main(不是 merge!),清掉已经 squash 过的 wip 痕迹:
   ```
   git checkout dev
   git reset --hard origin/main
   git push --force-with-lease
   git checkout main                     # 默认留在 main,等下次主动切
   ```

   **为什么 reset 不 merge**:dev 上的 wip commit 已经被 squash 进 main 一条新 SHA 的 commit。
   `git merge main` 会因为 tree 相同只加个空 merge commit,导致 dev 永远比 main 多两条 dangling
   commit(history 看着 ahead 但内容相同)。reset 直接对齐,dev 重新当干净的 wip 中转站。
   `--force-with-lease` 是安全的 force-push:只覆盖你最后看到的状态,对面机器偷偷动过 dev
   会被拒绝。dev 是个人 wip 分支,这个 trade-off 合理。

## 安全规则

- **绝不** `git push --force` 到 main。dev 上 ship 后的对齐 reset **可以**用 `--force-with-lease`(不是裸 `--force`),因为 dev 是个人 wip 分支且语义上 ship 后理应清空。其他场景动 dev 的 force-with-lease 仍要用户主动要求。
- **绝不**自动决定 stash:本地有未提交改动遇到 pull / ship,**停下来问**
- **绝不**在 ship 时用"wip" / 自动生成的语义 message:必须问用户
- **绝不**删 dev 分支
- 拉完 / 推完 / ship 完都跑一次 `git status` 确认状态

## 首次设置(用户从未跑过这个 skill 时)

```
git checkout -b dev                      # 从当前 HEAD 拉 dev
git push -u origin dev
```

之后两台电脑都 `git fetch && git checkout dev` 就接上同一条分支。

## 不该这个 skill 干的事

- **版本号 bump / archive 上线版本**:这些应该走正常 main commit(版本号必须有干净历史可追)。在 dev 上 bump 没意义,反正 ship 时 squash 成一个 commit。
- **冲突解决**:遇到 merge conflict 把现状报告给用户,让用户决定。skill 不自动选择 ours/theirs。
- **rebase / cherry-pick**:超出本 skill 范围,用户要这个让他们手动来。

## 常见坑

- **A 推完 B 没拉就开始改** → B 推时会被 reject(non-fast-forward)。让 B 先 `git pull --rebase` 再 push。
- **dev 跟 main 都各自有新 commit** → ship 时 `git pull` 在 main 上会引入 merge commit。让用户决定要不要 rebase main 整理。
- **第一次在新电脑上跑** → 需要先 `git fetch origin && git checkout dev`,本 skill 会自动处理。
