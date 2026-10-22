#!/bin/zsh
set -euo pipefail
echo "Remove the Hogtied administrator helper. The menu bar app and its preferences will remain installed."
sudo -v
sudo /bin/launchctl bootout system/local.memoryhogkiller.helper 2>/dev/null || true
sudo /bin/rm -f /Library/LaunchDaemons/local.memoryhogkiller.helper.plist /Library/PrivilegedHelperTools/local.memoryhogkiller.helper
sudo /bin/rm -f "/Library/Application Support/MemoryHogKiller/Trust.plist" "/Library/Application Support/MemoryHogKiller/Uninstall Admin Helper.command"
sudo /bin/rmdir "/Library/Application Support/MemoryHogKiller" 2>/dev/null || true
sudo /usr/sbin/pkgutil --forget local.memoryhogkiller.admin >/dev/null 2>&1 || true
echo "Administrator helper removed."
