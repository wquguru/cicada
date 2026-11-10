#!/bin/zsh
# Downloads webrtc-audio-processing 2.1 (BSD, freedesktop's standalone build of WebRTC's audio
# processing, AEC3 included), checks its SHA-256 and builds it static, release, into
# $AEC_LAB/webrtc-src/install (default ~/.cache/cicada-aec-lab). Needs meson + ninja (Homebrew); a test
# bench only, nothing here ships in the app.
set -e
LAB=${AEC_LAB:-$HOME/.cache/cicada-aec-lab}
S=$LAB/webrtc-src
SHA=ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe
mkdir -p $S
if [[ ! -d $S/webrtc-audio-processing-2.1 ]]; then
  curl -sSfL -o $S/w.tar.xz https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz
  echo "$SHA  $S/w.tar.xz" | shasum -a 256 -c -
  tar xf $S/w.tar.xz -C $S
fi
cd $S/webrtc-audio-processing-2.1
[[ -d build ]] || meson setup build --default-library=static --buildtype=release -Dprefix="$S/install" | tail -2
ninja -C build | tail -1
ninja -C build install | tail -1
