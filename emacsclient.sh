#!/usr/bin/env bash

emacs-server-running () {
    pgrep -f "emacs.*--daemon" &>/dev/null
    return $?
}

if ! emacs-server-running; then
    emacs --daemon
fi

if emacs-server-running; then
    exec emacsclient -t $*
fi
