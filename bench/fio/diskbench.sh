#!/usr/bin/env bash
# Disk benchmark via fio. Run INSIDE a running instance (fly ssh console /
# render shell). Measures the four numbers that matter for a Rails+Postgres box:
#   1) sequential write throughput   2) sequential read throughput
#   3) random 4K read IOPS           4) fsync latency (Postgres commit path)
#
# Usage:  TARGET_DIR=/data ./diskbench.sh   # persistent volume
#         TARGET_DIR=/tmp   ./diskbench.sh   # ephemeral/scratch disk
#
# NOTE: Heroku dynos have NO persistent disk — only run the /tmp (ephemeral)
# pass there and label it as such.

set -euo pipefail
DIR="${TARGET_DIR:-/tmp}"
SIZE="${SIZE:-1G}"
OUT="${OUT:-fio-$(basename "$DIR")-$(date +%s).json}"
mkdir -p "$DIR/optrails-fio"
cd "$DIR/optrails-fio"

if ! command -v fio >/dev/null 2>&1; then
  echo "fio not installed. In the container: apt-get update && apt-get install -y fio" >&2
  exit 1
fi

echo "[fio] target=$DIR size=$SIZE -> $OUT"
fio --output-format=json --output="$OUT" \
    --name=seqwrite --rw=write --bs=1m --size="$SIZE" --end_fsync=1 \
    --name=seqread  --rw=read  --bs=1m --size="$SIZE" \
    --name=randread --rw=randread --bs=4k --size="$SIZE" --iodepth=32 --numjobs=1 \
    --name=fsync    --rw=write --bs=4k --size=256m --fsync=1

echo "[fio] wrote $DIR/optrails-fio/$OUT"
rm -f "$DIR"/optrails-fio/seqwrite.* "$DIR"/optrails-fio/seqread.* \
      "$DIR"/optrails-fio/randread.* "$DIR"/optrails-fio/fsync.* 2>/dev/null || true
