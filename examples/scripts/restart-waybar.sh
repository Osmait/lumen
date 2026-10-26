#!/bin/bash

# @lumen.schemaVersion 1
# @lumen.title Restart Waybar
# @lumen.mode silent
# @lumen.icon 🔄
# @lumen.packageName Desktop

pkill -x waybar
setsid waybar >/dev/null 2>&1 &
