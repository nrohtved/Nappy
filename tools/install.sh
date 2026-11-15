#!/bin/zsh
# Builds and installs the two versions side by side:
#   Dev    (Release configuration)  ->  /Applications/Nappy Dev.app   (bundle id devplaceholder.GPRJU0JM.Nappy)
#   Public (Public configuration)   ->  /Applications/Nappy.app       (bundle id app.nortved.Nappy)
# Usage: tools/install.sh [dev|public|both]   (default: both)
# Run only one of them at a time: both would slow down the same apps.
set -e
cd "$(dirname "$0")/.."
which=${1:-both}
build=/tmp/nappy-build

build_config() {
  rm -rf "$build/Build/Products/$1/Nappy.app"
  xcodebuild -project Nappy.xcodeproj -scheme Nappy -configuration "$1" -derivedDataPath "$build" build 2>&1 | grep -E "error:|BUILD"
}

pkill -x Nappy 2>/dev/null || true   # Nappy puts every app back to normal when it quits
sleep 2

if [[ $which == dev || $which == both ]]; then
  build_config Release
  rm -rf "/Applications/Nappy Dev.app"
  ditto "$build/Build/Products/Release/Nappy.app" "/Applications/Nappy Dev.app"
fi
if [[ $which == public || $which == both ]]; then
  build_config Public
  rm -rf "/Applications/Nappy.app"
  ditto "$build/Build/Products/Public/Nappy.app" "/Applications/Nappy.app"
fi
echo "installed: $which"
