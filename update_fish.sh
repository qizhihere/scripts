#!/usr/bin/env bash

TMP_DIR=/tmp/$(tr -dc 0-9a-zA-Z < /dev/urandom | head -c8)

mkdir -p $TMP_DIR && cd $TMP_DIR && \
    git clone https://github.com/qizhihere/fish.git fish && {
        mkdir -p ~/.config/fish && \
        mv fish/config.fish ~/.config/fish/ && \
        mv fish/.dircolors ~/ && \
        rm -rf ~/.oh-my-fish && mv fish/.oh-my-fish ~/ && \
        fish -c "omf install"

        type -a percol &>/dev/null && \
        rm -rf ~/.percol.d && mv fish/.percol.d ~/
    } && \
cd .. && rm -rf $TMP_DIR
