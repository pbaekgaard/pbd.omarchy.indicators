pragma Singleton
import QtQuick
import Quickshell.Io

// Shared lock state for the AI-lockout indicator. The indicators widget can
// render this indicator as two independent QML instances at once (one for
// the "active" bar block, one for the "inactive"/dimmed block), each of
// which used to poll `ai-lockout.sh status` on its own schedule. That meant
// after a toggle, only the instance that triggered it updated immediately;
// its sibling held stale state until its own next ~10s timer tick, which
// looked like the icon vanishing for a few seconds before "reappearing" in
// the other block. Centralizing the state here means every indicator
// instance reads/writes the same property, so both blocks update in lockstep.
Item {
  id: root

  readonly property string scriptPath: String(Qt.resolvedUrl("ai-lockout.sh")).replace("file://", "")
  property bool locked: false

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function toggle() {
    if (!toggleProc.running) toggleProc.running = true
  }

  Component.onCompleted: refresh()

  Process {
    id: statusProc
    command: ["bash", root.scriptPath, "status"]
    onExited: function(exitCode) {
      root.locked = exitCode === 0
    }
  }

  Process {
    id: toggleProc
    command: ["bash", root.scriptPath, "toggle"]
    onExited: function(exitCode) {
      // Exit 3 means already locked: unlocking requires the gated terminal flow.
      if (exitCode === 3) unlockProc.running = true
      else root.refresh()
    }
  }

  Process {
    id: unlockProc
    command: ["omarchy-launch-floating-terminal-with-presentation", "bash '" + root.scriptPath + "' unlock"]
    onExited: function(exitCode) {
      root.refresh()
    }
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }
}
