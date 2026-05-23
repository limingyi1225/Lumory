#!/usr/bin/env bash
# PostToolUse hook: Edit/Write/MultiEdit 到 Localizable.strings 后检查中英文 key 同步。
# 失败不阻塞对话(退 0 永远),只把语法错误 / 重复 key / 缺失 key 回声到 stderr。

file_path=$(jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

project_dir="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
if [ -z "$project_dir" ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  project_dir="$(cd "$script_dir/../.." && pwd)"
fi

case "$file_path" in
  */Chronote/en.lproj/Localizable.strings|Chronote/en.lproj/Localizable.strings|./Chronote/en.lproj/Localizable.strings|\
  */Chronote/zh-Hans.lproj/Localizable.strings|Chronote/zh-Hans.lproj/Localizable.strings|./Chronote/zh-Hans.lproj/Localizable.strings)
    ;;
  *)
    exit 0
    ;;
esac

en_file="$project_dir/Chronote/en.lproj/Localizable.strings"
zh_file="$project_dir/Chronote/zh-Hans.lproj/Localizable.strings"
[ -f "$en_file" ] && [ -f "$zh_file" ] || exit 0
command -v plutil >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

lint_output=$(plutil -lint "$en_file" "$zh_file" 2>&1)
if [ $? -ne 0 ]; then
  echo "hooks: Localizable.strings syntax error" >&2
  echo "$lint_output" >&2
  exit 0
fi

duplicate_keys() {
  sed -nE 's/^"(([^"\\]|\\.)+)"[[:space:]]*=.*/\1/p' "$1" | LC_ALL=C sort | uniq -d
}

en_duplicates=$(duplicate_keys "$en_file")
zh_duplicates=$(duplicate_keys "$zh_file")
if [ -n "$en_duplicates" ] || [ -n "$zh_duplicates" ]; then
  echo "hooks: duplicate Localizable.strings key(s)" >&2
  if [ -n "$en_duplicates" ]; then
    while IFS= read -r key; do
      printf 'EN DUPLICATE: %s\n' "$key" >&2
    done <<< "$en_duplicates"
  fi
  if [ -n "$zh_duplicates" ]; then
    while IFS= read -r key; do
      printf 'ZH DUPLICATE: %s\n' "$key" >&2
    done <<< "$zh_duplicates"
  fi
fi

en_keys=$(mktemp "${TMPDIR:-/tmp}/lumory-i18n-en.XXXXXX")
zh_keys=$(mktemp "${TMPDIR:-/tmp}/lumory-i18n-zh.XXXXXX")
trap 'rm -f "$en_keys" "$zh_keys"' EXIT

plutil -convert json -o - "$en_file" | jq -r 'keys[]' | LC_ALL=C sort > "$en_keys"
plutil -convert json -o - "$zh_file" | jq -r 'keys[]' | LC_ALL=C sort > "$zh_keys"

missing_output=$(comm -3 "$en_keys" "$zh_keys")
if [ -n "$missing_output" ]; then
  echo "hooks: Localizable.strings key mismatch" >&2
  tab=$'\t'
  while IFS= read -r line; do
    case "$line" in
      "$tab"*) printf 'ZH-ONLY: %s\n' "${line#$tab}" >&2 ;;
      *) printf 'EN-ONLY: %s\n' "$line" >&2 ;;
    esac
  done <<< "$missing_output"
fi

if [ -z "$en_duplicates$zh_duplicates$missing_output" ]; then
  echo "hooks: Localizable.strings keys OK" >&2
fi

exit 0
