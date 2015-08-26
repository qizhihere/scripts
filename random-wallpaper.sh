#!/usr/bin/env bash

LOCK=/tmp/.$(basename "$0").lock
exec 200<>"$LOCK"
flock -n 200 || exit 1

WALLPAPER_DIR="/home/qizhi/Pictures/Wallpapers/normal/"

find "$WALLPAPER_DIR/" -type f -regex ".*\.\(png\|jpe?g\)" |
    shuf -n1 | xargs -I__ feh --bg-scale "__"

exec 200>&-
rm "$LOCK" &>/dev/null
