#!/bin/zsh
# press.sh <repo>: one real talk-key sentence. Interpreting on, hold the key, the phone says the Chinese
# sentence 2 s in (the unit is made at key-down, ~1.6 s), let go, wait for the cycle to end; the log
# says what was heard, sent and spoken, and when the echo-cancelling unit was let go of.
cd "${0:A:h}"
L=$1/tools/lsctl; LOG=/tmp/livesubs-dev-debug.log
$L speakOn >/dev/null; sleep 4
mark=$(wc -l < $LOG)
$L talkDown >/dev/null
python3 phone.py play work/near.wav --at $(python3 -c "import time;print(time.time()+2)")
sleep 0.6
$L talkUp >/dev/null
$L --wait 'speak.phase == "idle"' --timeout 60 >/dev/null; sleep 1.5
tail -n +$((mark + 1)) $LOG | grep -aE "speak|voice mic|voice output|ming|translate|Ming" | cut -c12-
$L speakOff >/dev/null
