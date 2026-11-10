#!/bin/zsh
# Builds ./aec against webrtc-audio-processing 2.1 (build-apm.sh), then runs gate3.py + aec on the
# last aecDump with each extra lead given (ms), printing per-second ERLE.
cd "${0:A:h}"
[[ -x transcribe ]] || swiftc -O ../transcribe.swift -o transcribe 2>&1 | grep error:
[[ -x rec ]] || swiftc -O rec.swift -o rec 2>&1 | grep error:
APM=${AEC_LAB:-$HOME/.cache/cicada-aec-lab}/webrtc-src
[[ -d $APM/install ]] || zsh build-apm.sh
clang++ -std=c++17 -O2 -DWEBRTC_LIBRARY_IMPL -DWEBRTC_POSIX -DWEBRTC_MAC -DWEBRTC_APM_DEBUG_DUMP=0 -I$APM/install/include/webrtc-audio-processing-2 \
  -I$APM/install/include -I$APM/webrtc-audio-processing-2.1/webrtc aec.cpp $APM/install/lib/libwebrtc-audio-processing-2.a \
  $(ls $APM/webrtc-audio-processing-2.1/build/subprojects/abseil-cpp-*/*.a) -framework CoreFoundation -o aec || exit 1
for extra in $@; do
  python3 gate3.py work $extra
  PER_SEC=1 ./aec 48000 work/ref.raw work/mic.raw work/out.raw | head -14
done
