import QtQuick
import qs.Ui
import "." as Local

BarIndicator {
  id: root

  readonly property string lockedGlyph: "󱚧"
  readonly property string unlockedGlyph: "󰚩"

  // When true, the icon is highlighted while AI is allowed instead of while it's blocked.
  readonly property bool invertMode: setting("aiLockoutInvert", false) === true

  // Backed by a shared singleton (AiLockoutService) so every instance of this
  // indicator (active-block copy and inactive-block copy) reflects the same
  // lock state instantly instead of each polling independently.
  readonly property bool locked: Local.AiLockoutService.locked

  active: invertMode ? !locked : locked
  activeText: invertMode ? unlockedGlyph : lockedGlyph
  inactiveText: invertMode ? lockedGlyph : unlockedGlyph
  activeTooltipText: invertMode ? "AI CLIs and sites allowed - click to block" : "AI CLIs (copilot, claude, opencode, codex) and sites (ChatGPT, Claude, Gemini, Copilot, Perplexity) blocked - click to allow"
  inactiveTooltipText: invertMode ? "AI CLIs (copilot, claude, opencode, codex) and sites (ChatGPT, Claude, Gemini, Copilot, Perplexity) blocked - click to allow" : "AI CLIs and sites allowed - click to block"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return (value === undefined || value === null) ? fallback : value
  }

  onPressed: function() {
    Local.AiLockoutService.toggle()
  }
}
