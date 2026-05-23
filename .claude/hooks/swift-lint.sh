#!/usr/bin/env bash
# PostToolUse hook: Edit/Write/MultiEdit 到 Swift 源文件后自动跑 SwiftLint --fix。
# 失败不阻塞对话(退 0 永远);未安装 swiftlint 时静默跳过。

file_path=$(jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

project_dir="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
if [ -z "$project_dir" ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  project_dir="$(cd "$script_dir/../.." && pwd)"
fi
case "$file_path" in
  /*) target_file="$file_path" ;;
  *) target_file="$project_dir/${file_path#./}" ;;
esac

case "$file_path" in
  */Chronote/*.swift|Chronote/*.swift|./Chronote/*.swift|\
  */LumoryWidgets/*.swift|LumoryWidgets/*.swift|./LumoryWidgets/*.swift|\
  */LumoryWidgetShared/*.swift|LumoryWidgetShared/*.swift|./LumoryWidgetShared/*.swift)
    [ -f "$target_file" ] || exit 0
    command -v swiftlint >/dev/null 2>&1 || exit 0
    cd "$project_dir" || exit 0

    # 注意:SwiftLint 0.63+ 移除了 `--path`,路径走位置参数(0.40 起 deprecated,0.63 直接 Unknown option)。
    swiftlint lint --fix --quiet "$target_file" >/dev/null 2>&1
    swiftlint lint --quiet "$target_file" >&2 || true
    echo "hooks: swiftlint → $(basename "$target_file")" >&2
    ;;
esac

exit 0
