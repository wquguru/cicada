#!/bin/zsh
# hyb.sh <repo> <db> <hold>: the hybrid output with that gate, for the silent press and the real
# double-talk round, through Ming.
cd "${0:A:h}"
export HYB_DB=$2 HYB_HOLD=$3
zsh silent.sh >/dev/null; zsh variants.sh >/dev/null
cp work/s_hyb.wav work/s_hyb_$2.wav; cp work/v_hyb.wav work/v_hyb_$2.wav
zsh ming.sh $1 ${0:A:h}/work/s_hyb_$2.wav ${0:A:h}/work/v_hyb_$2.wav 2>&1 | grep Ming
