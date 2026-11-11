#!/bin/sh
# usage: scripts/sim-find.sh first last steps [tail]
# Runs each seed in its own process (ReleaseSafe) and prints the first failing seed with
# the tail of its debug trace.
first=$1; last=$2; steps=$3; lines=$4
[ -z "$lines" ] && lines=40
./zig/zig build -Doptimize=ReleaseSafe 2>&1 | head -20
s=$first
while [ $s -le $last ]; do
  if ! ./zig-out/bin/tatami-sim $s $steps >/dev/null 2>&1; then
    echo "FAIL seed $s"
    ./zig/zig build 2>&1 | head -20
    ./zig-out/bin/tatami-sim $s $steps 2>&1 | grep -E 'panic|seed [0-9]+:|workspace=|src/(sim|engine|tree)\.zig' | head -8
    ./zig-out/bin/tatami-sim $s $steps --trace 2>&1 | grep -E '^ +[0-9]+ |^ +-> ' | tail -$lines
    exit 1
  fi
  s=$((s+1))
done
echo "all ok $first..$last at $steps steps"
