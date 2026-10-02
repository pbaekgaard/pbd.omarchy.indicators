#!/usr/bin/env bash
# Blocks or unblocks AI CLI tools by swapping their real executable for a
# stub that refuses to run.
#
# Usage: ai-lockout.sh {status|toggle|lock|unlock}
#   status  - prints "locked" (exit 0) or "unlocked" (exit 1)
#   toggle  - flips the current state
#   lock    - blocks the configured AI CLIs
#   unlock  - restores the configured AI CLIs
#
# Add/remove commands to guard in TARGETS below.
set -euo pipefail

TARGETS=(copilot claude opencode codex)

# Quickshell's Process spawns without a login shell environment, so $HOME may
# be unset even though this always runs as the invoking user. Fall back to
# the passwd database instead of assuming $HOME is inherited.
HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"

# Same reasoning as HOME: Quickshell's Process doesn't inherit the login
# shell PATH, so mise-managed tool directories may be missing. Append the
# common install locations so `command -v` can still find them.
export PATH="$PATH:$HOME/.local/bin:$HOME/.local/share/mise/shims:$HOME/.local/share/mise/installs/copilot/latest:$HOME/.local/share/mise/installs/opencode/latest:$HOME/.local/share/mise/installs/codex/latest/bin"

STATE_DIR="$HOME/.local/state/omarchy-ai-lockout"
LOCK_FLAG="$STATE_DIR/locked"
PATHS_FILE="$STATE_DIR/paths.list"
BACKUP_DIR="$STATE_DIR/backups"

# Marker embedded in the stub script so we can recognize it (and refuse to
# "back up" a stub over itself if lock is somehow called twice).
STUB_MARKER="# AI_LOCKOUT_STUB"

mkdir -p "$STATE_DIR" "$BACKUP_DIR"

is_locked() {
  [[ -f "$LOCK_FLAG" ]]
}

# Resolve the real executable behind a command name. mise-managed tools are
# fronted by shims that are symlinks to the `mise` binary itself, so chmod'ing
# `command -v`'s result would strip execute bits off `mise` (breaking every
# mise-shimmed tool at once) instead of the actual target. Prefer
# `mise which`, which reports the real installed binary, and fall back to
# `command -v` only when that fails (e.g. tools not managed by mise) - but
# still reject anything that resolves back to the mise binary itself.
resolve_path() {
  local cmd="$1" path resolved mise_bin
  if command -v mise >/dev/null 2>&1; then
    path=$(mise which "$cmd" 2>/dev/null || true)
    if [[ -n "$path" ]]; then
      echo "$path"
      return 0
    fi
  fi
  path=$(command -v "$cmd" 2>/dev/null || true)
  if [[ -z "$path" ]]; then
    return 0
  fi
  if command -v mise >/dev/null 2>&1; then
    mise_bin=$(command -v mise)
    resolved=$(readlink -f "$path" 2>/dev/null || echo "$path")
    if [[ "$resolved" == "$(readlink -f "$mise_bin" 2>/dev/null || echo "$mise_bin")" ]]; then
      # $path is a mise shim; we couldn't find the real binary, so skip it
      # rather than touch the shared mise executable.
      return 0
    fi
  fi
  echo "$path"
}

# Writes an executable stub at $path that, when run in place of $cmd,
# prints a message in the terminal and (when available) pops a desktop
# notification - so trying to launch a blocked AI CLI gives feedback instead
# of silently failing, whether that happens from a shell or from a
# .desktop/launcher entry (which may not have a visible terminal at all, or
# may close it before a printed message can be read).
write_stub() {
  local cmd="$1" path="$2" tmp
  # Write to a temp file in the same directory, then rename over the
  # target instead of writing to $path directly. If $path is the
  # currently-running executable (e.g. locking out `copilot` while this
  # very script is running as `copilot`), opening it for writing fails
  # with "Text file busy" - but rename() just repoints the directory
  # entry, so it works even while the old inode is still executing.
  tmp="$(dirname "$path")/.$(basename "$path").ai-lockout.tmp"
  cat > "$tmp" <<STUB
#!/usr/bin/env bash
$STUB_MARKER: $cmd
title="AI is off"
body="$cmd is blocked. Let's keep it that way."
echo "\$title: \$body" >&2
if command -v notify-send >/dev/null 2>&1; then
  notify-send -a "AI Lockout" -i dialog-information "\$title" "\$body" >/dev/null 2>&1 || true
fi
exit 1
STUB
  chmod +x "$tmp"
  mv -f "$tmp" "$path"
}

# Pops a desktop notification reporting the new lock state, so toggling the
# indicator gives feedback even when the bar icon update is easy to miss.
# Uses Omarchy's own notification sender (same one used elsewhere, e.g.
# ~/.config/hypr/input.lua) rather than notify-send directly, for consistent
# styling/glyph support across the desktop.
notify_state_change() {
  local glyph="$1" title="$2" body="$3"
  if command -v omarchy >/dev/null 2>&1; then
    omarchy notification send --app-name="AI Lockout" -g "$glyph" -u normal -t 6000 "$title" "$body" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send -a "AI Lockout" "$title" "$body" >/dev/null 2>&1 || true
  fi
}

do_lock() {
  if is_locked; then return 0; fi
  : > "$PATHS_FILE"
  for cmd in "${TARGETS[@]}"; do
    path=$(resolve_path "$cmd")
    if [[ -n "$path" && -x "$path" ]] && ! grep -q "^$STUB_MARKER" "$path" 2>/dev/null; then
      cp -p "$path" "$BACKUP_DIR/$cmd"
      write_stub "$cmd" "$path"
      echo "$cmd|$path" >> "$PATHS_FILE"
    fi
  done
  do_domain_lock
  touch "$LOCK_FLAG"
  notify_state_change "󱚧" "AI Availability: OFF" "AI CLIs and sites are now blocked."
}

do_unlock() {
  if [[ -f "$PATHS_FILE" ]]; then
    while IFS='|' read -r cmd path; do
      if [[ -n "$cmd" && -n "$path" && -f "$BACKUP_DIR/$cmd" ]]; then
        tmp="$(dirname "$path")/.$(basename "$path").ai-lockout.tmp"
        cp -p "$BACKUP_DIR/$cmd" "$tmp"
        mv -f "$tmp" "$path"
        rm -f "$BACKUP_DIR/$cmd"
      fi
    done < "$PATHS_FILE"
  fi
  do_domain_unlock
  rm -f "$LOCK_FLAG" "$PATHS_FILE"
  notify_state_change "󰚩" "AI Availability: ON" "AI CLIs and sites are now allowed."
}

# Domain blocking (chatgpt.com etc.) needs root to edit /etc/hosts, so it's
# handled by a separate root-owned script installed via
# ai-domain-block-install.sh, invoked here through a narrow NOPASSWD sudoers
# rule. If that's not installed yet, we skip it silently on lock/unlock but
# tell the user once via stderr/notification so they know domains aren't
# actually being blocked.
DOMAIN_BLOCK_BIN="/usr/local/bin/omarchy-ai-domain-block"

domain_block_notify_missing() {
  local msg="AI domain blocking isn't set up yet. Run: sudo bash $(dirname "$(readlink -f "$0")")/ai-domain-block-install.sh"
  echo "$msg" >&2
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "AI Lockout" -i dialog-information "AI domain blocking not set up" "$msg" >/dev/null 2>&1 || true
  fi
}

do_domain_lock() {
  if [[ -x "$DOMAIN_BLOCK_BIN" ]]; then
    sudo -n "$DOMAIN_BLOCK_BIN" lock 2>/dev/null || domain_block_notify_missing
  else
    domain_block_notify_missing
  fi
}

do_domain_unlock() {
  if [[ -x "$DOMAIN_BLOCK_BIN" ]]; then
    sudo -n "$DOMAIN_BLOCK_BIN" unlock 2>/dev/null || true
  fi
}

case "${1:-status}" in
  status)
    if is_locked; then echo locked; exit 0; else echo unlocked; exit 1; fi
    ;;
  toggle)
    if is_locked; then do_unlock; else do_lock; fi
    ;;
  lock) do_lock ;;
  unlock) do_unlock ;;
  *)
    echo "usage: ai-lockout.sh {status|toggle|lock|unlock}" >&2
    exit 2
    ;;
esac
