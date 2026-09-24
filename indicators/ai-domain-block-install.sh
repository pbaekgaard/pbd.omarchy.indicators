#!/usr/bin/env bash
# One-time (or re-run-to-update) installer for the AI domain blocker.
# Must be run with sudo: sudo bash ai-domain-block-install.sh
#
# Installs:
#   /usr/local/bin/omarchy-ai-domain-block   - root-owned enforcement script
#   /etc/omarchy-ai-lockout/domains.list      - root-owned copy of the domain list
#   /etc/sudoers.d/omarchy-ai-lockout         - narrow NOPASSWD rule so the bar
#                                                toggle can lock/unlock domains
#                                                without a password prompt
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this with sudo: sudo bash $0" >&2
  exit 1
fi

REAL_USER="${SUDO_USER:-$(logname)}"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -Dm755 "$PLUGIN_DIR/omarchy-ai-domain-block" /usr/local/bin/omarchy-ai-domain-block
chown root:root /usr/local/bin/omarchy-ai-domain-block

install -Dm644 "$PLUGIN_DIR/ai-domains.list" /etc/omarchy-ai-lockout/domains.list
chown root:root /etc/omarchy-ai-lockout/domains.list

SUDOERS_FILE="/etc/sudoers.d/omarchy-ai-lockout"
TMP_SUDOERS=$(mktemp)
echo "$REAL_USER ALL=(root) NOPASSWD: /usr/local/bin/omarchy-ai-domain-block lock, /usr/local/bin/omarchy-ai-domain-block unlock" > "$TMP_SUDOERS"
if visudo -cf "$TMP_SUDOERS" >/dev/null; then
  install -m 440 -o root -g root "$TMP_SUDOERS" "$SUDOERS_FILE"
  rm -f "$TMP_SUDOERS"
else
  rm -f "$TMP_SUDOERS"
  echo "sudoers syntax check failed; nothing was installed for $SUDOERS_FILE" >&2
  exit 1
fi

echo "Installed. AI domain blocking is now wired into the bar toggle for $REAL_USER."
echo "Edit $PLUGIN_DIR/ai-domains.list and re-run this installer (with sudo) to change the blocked domains."
