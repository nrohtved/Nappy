#!/bin/zsh
# Quits whichever Nappy is running (it restores every app first), then opens the one you ask for.
# Usage: tools/switch.sh dev|public
case "$1" in
  dev)    app="/Applications/Nappy Dev.app" ;;
  public) app="/Applications/Nappy.app" ;;
  *) echo "usage: $0 dev|public"; exit 1 ;;
esac
pkill -x Nappy 2>/dev/null || true
sleep 2
open "$app"
echo "opened: $app"
