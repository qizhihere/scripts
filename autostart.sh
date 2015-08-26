#!/usr/bin/env bash

command-exist-p () {
    local _command_exist=0
    for i in "$@"; do
        type -a "$i" &>/dev/null || _command_exist=1
    done
    return $_command_exist
}


# swap capslock and left ctrl
setxkbmap -option ctrl:swapcaps

# Xresources
[[ -f ~/.Xresources ]] && xrdb -merge ~/.Xresources

# touchpad
if command-exist-p synclient; then
    # enable vertical/horizontal two-finger scroll
    synclient VertTwoFingerScroll=1
    synclient HorizTwoFingerScroll=1
    # negative value for natural scroll
    synclient VertScrollDelta=-80
    synclient HorizScrollDelta=-80
fi

# mount dirs
/home/qizhi/scripts/mount.sh &

# networkmanager
nm-applet &

# start emacs
emacs --daemon &

# check system update
kalu &

# clipboard manager
clipit &

# mouse gesture
easystroke &

# fcitx input method
fcitx &

# autolock
xautolock -detectsleep \
          -time 30 -locker "$HOME/scripts/i3lock.sh" \
          -notify 30 \
          -notifier "notify-send -u critical -t 10000 -- 'LOCKING screen in 30 seconds'" &


# set VGA output resolution
xrandr --newmode 1368x768  85.25  1368 1440 1576 1784  768 771 781 798 -hsync +vsync
xrandr --addmode VGA-0 1368x768

# aria2c rpc service
aria2c -D --conf-path="$HOME/.aria2/aria2.conf"

# dropbox
command-exist-p proxychains && (proxychains dropbox &)

exit 0
