#!/bin/sh
# Pull audio from go2rtc RTSP, encode MP3, push to local Icecast.
# Each stream runs in a loop so a camera drop just reconnects.
set -u
RTSP="rtsp://go2rtc.home.svc.cluster.local:554"
# NOTE: no-brace $VAR so Flux postBuild envsubst (which only rewrites ${VAR})
# leaves it for the runtime shell to expand from the injected env var.
ICE="icecast://source:$ICECAST_SOURCE_PASSWORD@localhost:8000"
COMMON="-rtsp_transport tcp -fflags nobuffer -flags low_delay -timeout 15000000"
# -ar 44100: Tapo cameras output 8 kHz audio; 8 kHz MP3 is MPEG-2.5, which Chrome
# cannot decode (bytes arrive but readyState stays 0). Resample to 44.1 kHz (MPEG-1).
ENC="-vn -c:a libmp3lame -b:a 96k -ar 44100 -ac 1 -content_type audio/mpeg -f mp3"

run_single() { # $1 = go2rtc stream, $2 = mount
  while true; do
    ffmpeg -hide_banner -loglevel warning $COMMON -i "$RTSP/$1" $ENC "$ICE/$2.mp3"
    echo "[supervise] $2 exited, restarting in 2s"; sleep 2
  done
}

run_mix() { # sofia + nicolo -> both.mp3 (mono mix)
  while true; do
    ffmpeg -hide_banner -loglevel warning \
      $COMMON -i "$RTSP/sofias-room" \
      $COMMON -i "$RTSP/nicolos-room" \
      -filter_complex "amix=inputs=2:duration=longest:normalize=0" \
      $ENC "$ICE/both.mp3"
    echo "[supervise] both exited, restarting in 2s"; sleep 2
  done
}

run_single sofias-room  sofia  &
run_single nicolos-room nicolo &
run_mix                        &
wait
