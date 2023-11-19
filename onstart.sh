#!/bin/bash

WALLET=[WALLET]
WORKER=$(nvidia-smi -q -i 0 | grep 'Serial Number' | awk '{print $4}')
if ! tmux has-session -t miner 2>/dev/null; then
    tmux new -d -s miner
    tmux send-keys -t miner "cd /usr/local/bin/onezerominer-linux; ./onezerominer -a dynex -o dnx.eu.neuropool.net:19331 -w $WALLET -p $WORKER" C-m
fi
