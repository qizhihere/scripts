#!/usr/bin/env bash

sudo pacman -S fcitx fcitx-rime fcitx-cloudpinyin fcitx-im fcitx-qt5  fcitx-configtool

export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS="@im=fcitx"
