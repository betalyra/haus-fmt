#!/bin/sh
# After Claude writes or edits a .haus file, run `haus check` on it and hand
# the errors back to Claude (exit 2), so invalid data never goes unnoticed.
# Quiet when the file is valid, isn't a .haus file, or the haus CLI isn't
# installed. Reads the PostToolUse hook input (JSON) on stdin.

input=$(cat)

# The edited file's path: with jq when it's there, else from the raw JSON.
if command -v jq >/dev/null 2>&1; then
  file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_response.filePath // empty')
else
  file=$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
fi

case "$file" in
  *.haus) ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0
command -v haus >/dev/null 2>&1 || exit 0

output=$(haus check --color never "$file" 2>&1)
status=$?
# 0: valid. 1: the file is invalid. 2: usage or I/O trouble (a missing schema, …).
[ "$status" -eq 0 ] && exit 0
printf 'haus check found problems in %s; fix them and check again:\n%s\n' "$file" "$output" >&2
[ "$status" -eq 1 ] && exit 2
exit 0
