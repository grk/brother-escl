#!/bin/zsh
# Builds brother-escl and installs it as a per-user launchd agent that starts at login.
# Usage: ./install.sh [printer-ip]      (./install.sh --uninstall to remove)
# The printer is found automatically; an IP is only a starting hint.
set -euo pipefail

LABEL=io.github.grk.brother-escl
DOMAIN="gui/$(id -u)"
BIN="$HOME/.local/bin/brother-escl"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/brother-escl.log"
STATE="$HOME/Library/Application Support/brother-escl"

# `launchctl bootout` returns before the job is gone; bootstrapping too early fails with EIO.
stop_agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || return 0
  for _ in {1..50}; do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
}

xml_escape() {
  local s=${1//&/&amp;}
  s=${s//</&lt;}
  print -r -- "${s//>/&gt;}"
}

if [[ "${1:-}" == "--uninstall" ]]; then
  stop_agent
  rm -f "$PLIST" "$BIN" "$LOG"
  rm -rf "$STATE"
  echo "uninstalled"
  exit 0
fi

ARGS=("$BIN")
[[ -n "${1:-}" ]] && ARGS+=(--host "$1")

cd "${0:A:h}"
swift build -c release
mkdir -p "${BIN:h}" "${PLIST:h}"
stop_agent
install -m 755 .build/release/brother-escl "$BIN"

{
  print -r -- '<?xml version="1.0" encoding="UTF-8"?>'
  print -r -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  print -r -- '<plist version="1.0">'
  print -r -- '<dict>'
  print -r -- "  <key>Label</key><string>$LABEL</string>"
  print -r -- '  <key>ProgramArguments</key>'
  print -r -- '  <array>'
  for a in $ARGS; do print -r -- "    <string>$(xml_escape "$a")</string>"; done
  print -r -- '  </array>'
  print -r -- '  <key>RunAtLoad</key><true/>'
  print -r -- '  <key>KeepAlive</key><true/>'
  print -r -- '  <key>ProcessType</key><string>Background</string>'
  print -r -- "  <key>StandardErrorPath</key><string>$(xml_escape "$LOG")</string>"
  print -r -- "  <key>StandardOutPath</key><string>$(xml_escape "$LOG")</string>"
  print -r -- '</dict>'
  print -r -- '</plist>'
} > "$PLIST"
plutil -lint "$PLIST" >/dev/null

for attempt in {1..5}; do
  launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break
  (( attempt == 5 )) && { echo "launchctl bootstrap failed" >&2; exit 1; }
  sleep 1
done
echo "installed; logs: $LOG"
