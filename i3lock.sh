#!/usr/bin/env bash

exec 2>/dev/null
exec 1>/dev/null
IMGS_DIR="$HOME/Pictures/Wallpapers/normal"

command-exist-p () {
    local _command_exist=0
    for i in "$@"; do
        type -a "$i" &>/dev/null || _command_exist=1
    done
    return $_command_exist
}

blur-shot () {
    scrot /tmp/screenshot.png
    convert /tmp/screenshot.png -blur 0x5 /tmp/screenshotblur.png
    echo "/tmp/screenshotblur.png"
}

random-pic () {
    if [ ! -d "$1" ]; then
        echo "error: invalid arguments $*"
        echo "Usage: random-pic directory"
        return 1
    fi

    local _pic=$(shuf -n1 -e $(find "$1" -regex ".*\.\(png\|jpe?g\)"))
    local _tmp_dir="/tmp/i3lock_bg"
    local _fpath=$_tmp_dir/$(date +'%Y%m%d%H')".png"

    [ -d $_tmp_dir ] || mkdir -p $_tmp_dir
    find $_tmp_dir -iname "*.png" -ctime +1 -exec rm \{\} \;

    if [ -f $_fpath ]; then
        echo $_fpath
        return
    else
        if convert "$_pic" "$_fpath"; then
            echo "$_fpath"
            return 0
        else
            return 1
        fi
    fi
}

# randomly select wallpaper src
if [ $(shuf -i 1-3 -n1) = "3" ]; then
    pic=$(random-pic "$IMGS_DIR")
else
    pic=$(blur-shot)
fi

command-exist-p i3lock && exec i3lock -d -i "$pic"
