#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: install_local_root.sh [--preflight] <app-source> [designated-requirement]" >&2
}

PREFLIGHT_ONLY=0
if [[ ${1:-} == "--preflight" ]]; then
  PREFLIGHT_ONLY=1
  shift
fi
if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

APP_SOURCE="$1"
EXPECTED_REQUIREMENT="${2:-}"
if [[ -L "$APP_SOURCE" || ! -d "$APP_SOURCE" ]]; then
  echo "The application source must be a real directory, not a symlink." >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP_SOURCE"
if [[ -z "$EXPECTED_REQUIREMENT" ]]; then
  EXPECTED_REQUIREMENT=$(
    /usr/bin/codesign -d -r- "$APP_SOURCE" 2>&1 \
      | /usr/bin/sed -n 's/^# designated => //p'
  )
fi
if [[ -z "$EXPECTED_REQUIREMENT" ]]; then
  echo "Could not read the application's designated requirement." >&2
  exit 1
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  OUTER_STAGING_ROOT=$(/usr/bin/mktemp -d /private/tmp/local.wty.BrightnessControl.install.XXXXXX)
  OUTER_STAGING_APP="$OUTER_STAGING_ROOT/Brightness Control.app"
  OUTER_STAGING_INSTALLER="$OUTER_STAGING_ROOT/install_local_root.sh"
  trap '/bin/rm -rf "$OUTER_STAGING_ROOT"' EXIT

  /usr/bin/ditto "$APP_SOURCE" "$OUTER_STAGING_APP"
  /bin/cp "$0" "$OUTER_STAGING_INSTALLER"
  /bin/chmod 755 "$OUTER_STAGING_INSTALLER"
  /usr/bin/codesign --verify --deep --strict "$OUTER_STAGING_APP"

  if [[ $PREFLIGHT_ONLY -eq 1 ]]; then
    echo "PREFLIGHT_APP=$APP_SOURCE"
    echo "DESIGNATED_REQUIREMENT=$EXPECTED_REQUIREMENT"
    exit 0
  fi

  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'set commandText to quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv)' \
    -e 'do shell script commandText with administrator privileges' \
    -e 'end run' \
    "$OUTER_STAGING_INSTALLER" \
    "$OUTER_STAGING_APP" \
    "$EXPECTED_REQUIREMENT"
  exit 0
fi

if [[ $PREFLIGHT_ONLY -eq 1 ]]; then
  /usr/bin/codesign --verify --deep --strict "$APP_SOURCE"
  echo "PREFLIGHT_APP=$APP_SOURCE"
  echo "DESIGNATED_REQUIREMENT=$EXPECTED_REQUIREMENT"
  exit 0
fi

APP_DESTINATION="/Applications/Brightness Control.app"
STAGING_ROOT="/private/var/tmp/local.wty.BrightnessControl.install-$$"
STAGING_APP="$STAGING_ROOT/Brightness Control.app"
BACKUP_APP="/Applications/Brightness Control.app.backup-$(date +%Y%m%d-%H%M%S)"
PRIVILEGED_TOOLS_DIRECTORY="/Library/PrivilegedHelperTools"
HELPER_SOURCE_RELATIVE="Contents/Library/HelperTools/BrightnessControlSleepHelper"
HELPER_DESTINATION="$PRIVILEGED_TOOLS_DIRECTORY/local.wty.BrightnessControl.SleepHelper"
STAGING_HELPER="$PRIVILEGED_TOOLS_DIRECTORY/.local.wty.BrightnessControl.SleepHelper.install-$$"
REQUIREMENT_FILE="$PRIVILEGED_TOOLS_DIRECTORY/local.wty.BrightnessControl.SleepHelper.caller.requirement"
STAGING_REQUIREMENT="$PRIVILEGED_TOOLS_DIRECTORY/.local.wty.BrightnessControl.SleepHelper.caller.requirement.install-$$"
DAEMON_PLIST="/Library/LaunchDaemons/local.wty.BrightnessControl.SleepHelper.plist"
DAEMON_LABEL="local.wty.BrightnessControl.SleepHelper"
LEGACY_PLIST_RELATIVE="Contents/Resources/local.wty.BrightnessControl.SleepHelper.legacy.plist"

cleanup() {
  if [[ -d "$STAGING_ROOT" ]]; then
    rm -rf "$STAGING_ROOT"
  fi
  rm -f "$STAGING_HELPER"
  rm -f "$STAGING_REQUIREMENT"
}
trap cleanup EXIT

/bin/mkdir -m 700 "$STAGING_ROOT"
/usr/bin/ditto "$APP_SOURCE" "$STAGING_APP"
/usr/sbin/chown -R root:wheel "$STAGING_APP"
/bin/chmod -R go-w "$STAGING_APP"
/usr/bin/codesign --verify --deep --strict "$STAGING_APP"

ACTUAL_REQUIREMENT=$(
  /usr/bin/codesign -d -r- "$STAGING_APP" 2>&1 \
    | /usr/bin/sed -n 's/^# designated => //p'
)
if [[ "$ACTUAL_REQUIREMENT" != "$EXPECTED_REQUIREMENT" ]]; then
  echo "The staged app does not match the approved code requirement." >&2
  exit 1
fi

/usr/bin/plutil -lint "$STAGING_APP/$LEGACY_PLIST_RELATIVE" >/dev/null
/usr/bin/codesign --verify --strict "$STAGING_APP/$HELPER_SOURCE_RELATIVE"
HELPER_SIGNING_FLAGS=$(
  /usr/bin/codesign -dv --verbose=4 "$STAGING_APP/$HELPER_SOURCE_RELATIVE" 2>&1 \
    | /usr/bin/sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p'
)
if [[ "$HELPER_SIGNING_FLAGS" != *runtime* ]]; then
  echo "The privileged helper is not protected by Hardened Runtime." >&2
  exit 1
fi

if [[ ! -e "$PRIVILEGED_TOOLS_DIRECTORY" ]]; then
  /bin/mkdir -m 755 "$PRIVILEGED_TOOLS_DIRECTORY"
  /usr/sbin/chown root:wheel "$PRIVILEGED_TOOLS_DIRECTORY"
fi
if [[ -L "$PRIVILEGED_TOOLS_DIRECTORY" || ! -d "$PRIVILEGED_TOOLS_DIRECTORY" ]]; then
  echo "The privileged helper directory is not a real directory." >&2
  exit 1
fi
PRIVILEGED_DIRECTORY_OWNER=$(/usr/bin/stat -f '%u' "$PRIVILEGED_TOOLS_DIRECTORY")
PRIVILEGED_DIRECTORY_MODE=$(/usr/bin/stat -f '%Lp' "$PRIVILEGED_TOOLS_DIRECTORY")
if [[ "$PRIVILEGED_DIRECTORY_OWNER" != "0" ]] \
  || (( (8#$PRIVILEGED_DIRECTORY_MODE & 0022) != 0 )); then
  echo "The privileged helper directory has unsafe ownership or permissions." >&2
  exit 1
fi
/usr/bin/install -o root -g wheel -m 755 \
  "$STAGING_APP/$HELPER_SOURCE_RELATIVE" \
  "$STAGING_HELPER"
/usr/bin/codesign --verify --strict "$STAGING_HELPER"
/usr/bin/printf '%s\n' "$EXPECTED_REQUIREMENT" > "$STAGING_ROOT/caller.requirement"
/usr/bin/install -o root -g wheel -m 600 \
  "$STAGING_ROOT/caller.requirement" \
  "$STAGING_REQUIREMENT"

/usr/bin/pkill -x BrightnessControlApp 2>/dev/null || true
/bin/launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
if [[ -e "$APP_DESTINATION" ]]; then
  /bin/mv "$APP_DESTINATION" "$BACKUP_APP"
fi
/bin/mv "$STAGING_APP" "$APP_DESTINATION"
/bin/mv -f "$STAGING_HELPER" "$HELPER_DESTINATION"
/bin/mv -f "$STAGING_REQUIREMENT" "$REQUIREMENT_FILE"

/usr/bin/install -o root -g wheel -m 644 \
  "$APP_DESTINATION/$LEGACY_PLIST_RELATIVE" \
  "$DAEMON_PLIST"

/bin/launchctl bootstrap system "$DAEMON_PLIST"
/bin/launchctl kickstart -k "system/$DAEMON_LABEL"

/usr/bin/codesign --verify --deep --strict "$APP_DESTINATION"
/bin/launchctl print "system/$DAEMON_LABEL" >/dev/null

echo "INSTALLED_APP=$APP_DESTINATION"
echo "BACKUP_APP=$BACKUP_APP"
echo "INSTALLED_HELPER=$HELPER_DESTINATION"
echo "DAEMON_LABEL=$DAEMON_LABEL"
