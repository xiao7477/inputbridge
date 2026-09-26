#!/bin/zsh
set -euo pipefail

source_app="$1"
destination_app="$2"
old_pid="$3"
agent_plist="$4"

for attempt in {1..100}; do
  if ! /bin/kill -0 "$old_pid" 2>/dev/null; then
    break
  fi
  /bin/sleep 0.2
done
if /bin/kill -0 "$old_pid" 2>/dev/null; then
  exit 1
fi

parent="${destination_app:h}"
/bin/mkdir -p "$parent"
incoming="$parent/.inputbridge-incoming-$$.app"
backup="$parent/.inputbridge-previous-$(/bin/date +%s)-$$.app"
/usr/bin/ditto "$source_app" "$incoming"
/usr/bin/codesign --verify --deep --strict "$incoming"
if [[ -e "$destination_app" ]]; then
  /bin/mv "$destination_app" "$backup"
fi
if ! /bin/mv "$incoming" "$destination_app"; then
  if [[ -e "$backup" ]]; then
    /bin/mv "$backup" "$destination_app"
  fi
  exit 1
fi

if ! /usr/bin/open -a "$destination_app"; then
  /bin/rm -rf "$destination_app"
  if [[ -e "$backup" ]]; then
    /bin/mv "$backup" "$destination_app"
    /usr/bin/open -a "$destination_app" || true
  fi
  exit 1
fi

# If this installation moved out of a protected folder, keep login launch on the new App.
if [[ -f "$agent_plist" ]]; then
  /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $destination_app/Contents/MacOS/InputBridge" "$agent_plist" 2>/dev/null || true
fi
