#!/bin/sh
set -e
cd "$(dirname "$0")"
zig build-lib -dynamic -OReleaseSafe -fPIC -lc src/plugin.zig -femit-bin=brainfuck.so
echo "Built brainfuck.so"
