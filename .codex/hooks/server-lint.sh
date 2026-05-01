#!/usr/bin/env bash
# PostToolUse hook: Edit/Write/MultiEdit 到 server/*.js 后自动跑 eslint --fix + prettier --write.
# 失败不阻塞对话(退 0 永远),结果回声到 stderr。直接调 server/node_modules/.bin,
# 绕过 npx 在 Node 22+ 下对 `--no` flag 的处理歧义(`--no` 不再是 --no-install 的别名)。

file_path=$(jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

case "$file_path" in
  */server/*.js)
    server_dir="${CLAUDE_PROJECT_DIR:-.}/server"
    [ -d "$server_dir/node_modules/.bin" ] || exit 0
    cd "$server_dir" || exit 0

    eslint_bin="$server_dir/node_modules/.bin/eslint"
    prettier_bin="$server_dir/node_modules/.bin/prettier"
    ran=()

    # exit 1 对 eslint --fix 是"修完仍有 unfixable issue",不是 failure,一律当作跑过。
    if [ -x "$eslint_bin" ]; then
      "$eslint_bin" --fix "$file_path" >/dev/null 2>&1
      ran+=("eslint")
    fi
    if [ -x "$prettier_bin" ]; then
      "$prettier_bin" --write --log-level=warn "$file_path" >/dev/null 2>&1
      ran+=("prettier")
    fi

    if [ ${#ran[@]} -gt 0 ]; then
      msg=$(printf "%s + " "${ran[@]}")
      echo "hooks: ${msg% + } → $(basename "$file_path")" >&2
    fi
    ;;
esac

exit 0
