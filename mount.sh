#!/usr/bin/env bash

# if we create direcotry automatically
#   when the mountpoint doesn't exist
AUTO_MKDIR=true
AUTO_REMOUNT=true

command-exist-p () {
    type -a "$*" >/dev/null 2>&1
    return
}

quit () {
    [ "$1" ] && echo $1
    [ "$2" ] && exit $2
    exit 1
}

is_mounted () {
    if [ $# -eq 1 ]; then
        df | awk '{print $1}' | grep "^$1$" >/dev/null 2>&1
        return
    elif [ $# -eq 2 ]; then
        df | awk '{print $1, $6}' | grep "^$1 $2$" >/dev/null 2>&1
        return
    else
        echo "error: invalid arguments: $@"
        echo "Usage: is_mounted paratition [mountpoint]"
        return 1
    fi
}

_mount () {
    # check arguments
    if [ $# -lt 2 ]; then
        echo "error: invalid arguments: $@"
        echo "Usage: mount-bind path mountpoint [options ...]"
        return 1
    fi

    # check direcotries
    [ ! -e "$1" ] && quit "error: $1 does not exist."
    if [ ! -e "$2" ]; then
        if [ $AUTO_MKDIR ]; then
            sudo mkdir -p $2
        else
            quit "error: mountpoint $1 does not exist."
        fi
    fi

    local _target=$(realpath "$1")
    local _mountpoint=$(realpath "$2")

    # check if paratition has been mounted
    if is_mounted "$_target" "$_mountpoint"; then
        if $AUTO_REMOUNT; then
            sudo umount -lR "$_mountpoint"
        else
            echo "$1 has been mounted on $_mountpoint"
            return 1
        fi
    fi

    # remove mount dirs so only options are kept.
    shift 2

    local _options=""
    [ "$*" ] && _options="$*"
    sudo mount "$_target" "$_mountpoint" $_options
    return
}

# check if ntfs-3g is installed
if ! command-exist-p ntfs-3g; then
    echo "Warning: ntfs-3g is not installed, ntfs parition will be mounted readonly."
fi

# mount partition and bind directories
if _mount /dev/disk/by-label/_Strg /mnt/E  -o uid=qizhi,gid=users,umask=0022; then
    _mount "/mnt/E/Downloads/"                  "/home/qizhi/Downloads/Win/"  --bind
    _mount "/mnt/E/库/Pictures/"                "/home/qizhi/Pictures/"       --bind
    _mount "/mnt/E/库/Video/"                   "/home/qizhi/Video/"          --bind
    _mount "/mnt/E/库/Music/音乐/"              "/home/qizhi/Music/"          --bind
    _mount "/mnt/E/Individual Documents Bank/"  "/home/qizhi/Docs/"           --bind
fi

_mount /dev/disk/by-label/_Soft /mnt/D -o uid=qizhi,gid=users,umask=0022
