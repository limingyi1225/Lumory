#!/usr/bin/env bash
# Codex PostToolUse hook entrypoint. Keep this legacy filename because
# .codex/hooks.json already points here; fan out to the shared Claude hooks.
# Every child hook is best-effort and must not block the conversation.

payload=$(cat)

project_dir="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-}}"
if [ -z "$project_dir" ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  project_dir="$(cd "$script_dir/../.." && pwd)"
fi

run_shared_hook() {
  local hook_path="$1"
  [ -x "$hook_path" ] || return 0
  printf '%s\n' "$payload" | CODEX_PROJECT_DIR="$project_dir" CLAUDE_PROJECT_DIR="$project_dir" "$hook_path" || true
}

run_shared_hook "$project_dir/.claude/hooks/server-lint.sh"
run_shared_hook "$project_dir/.claude/hooks/swift-lint.sh"
run_shared_hook "$project_dir/.claude/hooks/i18n-parity.sh"

exit 0
