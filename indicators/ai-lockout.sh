#!/usr/bin/env bash
# Blocks or unblocks AI CLI tools by swapping their real executable for a
# stub that refuses to run.
#
# Usage: ai-lockout.sh {status|toggle|menu-toggle|lock|unlock|unlock-now|exclude|exclusion}
#   status      - prints "locked" (exit 0) or "unlocked" (exit 1)
#   toggle      - locks if unlocked; if locked, exits 3 (caller must run `unlock`)
#   menu-toggle - like toggle, but opens the gated unlock in a floating
#                 terminal itself (for callers without a terminal, e.g. the menu)
#   lock        - blocks the configured AI CLIs (no friction)
#   unlock      - interactive gated unlock: password + cooldown + typed phrase
#   unlock-now  - ungated restore, used internally after the gate passes
#   exclude     - interactive picker for a date/time; locks AI and refuses
#                 every unlock until then (cold turkey)
#   exclusion   - prints the exclusion end time (exit 0) or nothing (exit 1)
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
EXCLUSION_FILE="$STATE_DIR/exclusion_until"

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

# Prints the exclusion end (epoch seconds) and succeeds while it's in the
# future; clears an expired exclusion.
exclusion_until() {
  local until
  [[ -f "$EXCLUSION_FILE" ]] || return 1
  until=$(<"$EXCLUSION_FILE")
  if [[ "$until" =~ ^[0-9]+$ ]] && (( until > $(date +%s) )); then
    echo "$until"
    return 0
  fi
  rm -f "$EXCLUSION_FILE"
  return 1
}

exclusion_refuse_message() {
  local until
  until=$(exclusion_until) || return 1
  echo "Exclusion active: AI stays off until $(date -d "@$until" '+%A %Y-%m-%d %H:%M')." >&2
  notify_state_change "󱚧" "AI exclusion active" "AI stays off until $(date -d "@$until" '+%a %d %b %H:%M')."
}

do_unlock() {
  if exclusion_refuse_message; then return 1; fi
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

UNLOCK_COOLDOWN=60
UNLOCK_PHRASE="I am choosing to turn AI back on"

# Unlocking is deliberately hard: lock is one click, but turning AI back on
# needs (1) a real password check, (2) a cooldown you must sit through, and
# (3) typing a confirmation phrase by hand. Ctrl-C at any point aborts.
unlock_gate() {
  if [[ ! -t 0 ]]; then
    echo "Unlock must be run from an interactive terminal." >&2
    return 1
  fi
  echo "Turning AI back on takes effort on purpose."
  echo
  echo "Step 1/3: password"
  sudo -k
  if ! sudo -v; then
    echo "Wrong password. AI stays off." >&2
    return 1
  fi
  sudo -k
  echo
  echo "Step 2/3: cooldown. Ask yourself if you really need AI right now."
  for ((i = UNLOCK_COOLDOWN; i > 0; i--)); do
    printf '\r  %2ds remaining (Ctrl-C to cancel) ' "$i"
    sleep 1
  done
  printf '\r%40s\r' ""
  echo
  echo "Step 3/3: type this exactly to confirm:"
  echo "  $UNLOCK_PHRASE"
  local answer
  read -r -p "> " answer
  if [[ "$answer" != "$UNLOCK_PHRASE" ]]; then
    echo "Phrase did not match. AI stays off." >&2
    return 1
  fi
  do_unlock
}

# Interactive picker (run in a terminal): choose a day, then a time. The
# exclusion can only be extended, never shortened.
exclude_picker() {
  if ! command -v gum >/dev/null 2>&1; then
    echo "gum is required for the exclusion picker." >&2
    return 1
  fi
  local current="" days=() labels=() i label day time picked epoch
  current=$(exclusion_until) || true
  echo "Trigger Exclusion: AI stays OFF until the time you pick. No way back before then."
  [[ -n "$current" ]] && echo "Current exclusion ends $(date -d "@$current" '+%A %Y-%m-%d %H:%M') (can only be extended)."
  echo
  for i in $(seq 0 30); do
    day=$(date -d "+$i day" +%F)
    label=$(date -d "$day" '+%a %d %b %Y')
    case $i in 0) label="$label (today)";; 1) label="$label (tomorrow)";; esac
    days+=("$day"); labels+=("$label")
  done
  echo "Day:"
  picked=$(printf '%s\n' "${labels[@]}" | gum choose --height 12) || return 1
  for i in "${!labels[@]}"; do [[ "${labels[$i]}" == "$picked" ]] && day="${days[$i]}"; done
  echo "Day: $picked"
  echo "Hour:"
  time=$(printf '%02d:00\n' $(seq 0 23) | gum choose --height 12 --selected "08:00") || return 1
  echo "Minute:"
  time="${time%:*}:$(printf '%02d\n' 00 15 30 45 | gum choose --height 4)" || return 1
  epoch=$(date -d "$day $time" +%s 2>/dev/null) || { echo "Invalid date." >&2; return 1; }
  if (( epoch <= $(date +%s) )); then
    echo "That time is in the past." >&2
    return 1
  fi
  if [[ -n "$current" ]] && (( epoch < current )); then
    echo "An existing exclusion can't be shortened." >&2
    return 1
  fi
  echo
  gum confirm "Block AI until $(date -d "@$epoch" '+%A %d %b %Y %H:%M')? You will NOT be able to turn it on before then." || return 1
  do_lock
  echo "$epoch" > "$EXCLUSION_FILE"
  notify_state_change "󱚧" "AI exclusion started" "AI stays off until $(date -d "@$epoch" '+%a %d %b %H:%M')."
}

case "${1:-status}" in
  status)
    if is_locked; then echo locked; exit 0; else echo unlocked; exit 1; fi
    ;;
  toggle)
    if is_locked; then exit 3; else do_lock; fi
    ;;
  menu-toggle)
    if is_locked; then
      exec omarchy-launch-floating-terminal-with-presentation "bash '$(readlink -f "$0")' unlock"
    else
      do_lock
    fi
    ;;
  exclude) exclude_picker ;;
  exclusion) exclusion_until ;;
  lock) do_lock ;;
  unlock)
    if is_locked; then
      if exclusion_refuse_message; then
        read -r -n 1 -s -p "Press any key to close." || true
        exit 1
      fi
      unlock_gate
    fi
    ;;
  unlock-now) do_unlock ;;
  *)
    echo "usage: ai-lockout.sh {status|toggle|menu-toggle|lock|unlock|unlock-now|exclude|exclusion}" >&2
    exit 2
    ;;
esac
