#!/bin/bash
# Adds AgentNudge's hooks to Claude Code's user settings, or removes them with --uninstall.
# Safe to run again: it replaces only its own entries and leaves every other hook alone.
# Sessions that were already running pick the hooks up when they are restarted.
set -euo pipefail

SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
command -v jq >/dev/null || { echo "jq is required: brew install jq" >&2; exit 1; }
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" || { echo "$SETTINGS is not valid JSON; not touching it." >&2; exit 1; }

cp "$SETTINGS" "$SETTINGS.agentnudge-backup"

MODE="install"
[ "${1:-}" = "--uninstall" ] && MODE="uninstall"

# The command checks for the helper first, so a removed app leaves silent hooks rather than errors.
HOOK='h="$HOME/.agentnudge/bin/agentnudge-hook"; [ -x "$h" ] && "$h" EVENT || true'

tmp="$(mktemp)"
jq --arg hook "$HOOK" --arg mode "$MODE" '
  def ours: (.hooks // []) | any((.command // "") | contains("agentnudge-hook"));
  def entry($event; $matcher):
    {hooks: [{type: "command", command: ($hook | sub("EVENT"; $event)), timeout: 5}]}
    + (if $matcher == null then {} else {matcher: $matcher} end);

  .hooks = (.hooks // {})
  | reduce (
      ["SessionStart", null],
      ["UserPromptSubmit", null],
      ["PreToolUse", "AskUserQuestion|ExitPlanMode"],
      ["PostToolUse", "*"],
      ["Notification", null],
      ["Stop", null],
      ["SessionEnd", null]
    ) as [$event, $matcher] (.;
      .hooks[$event] = (
        ((.hooks[$event] // []) | map(select(ours | not)))
        + (if $mode == "install" then [entry($event; $matcher)] else [] end)
      )
      | if (.hooks[$event] | length) == 0 then del(.hooks[$event]) else . end
    )
  | if (.hooks | length) == 0 then del(.hooks) else . end
' "$SETTINGS" > "$tmp"

# Write in place so the file keeps its permissions.
cat "$tmp" > "$SETTINGS"
rm -f "$tmp"

echo "AgentNudge hooks: $MODE done in $SETTINGS (backup: $SETTINGS.agentnudge-backup)"
