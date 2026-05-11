#!/bin/sh
set -e
cd "$(dirname "$0")"
zig build-lib -dynamic -OReleaseSafe -fPIC -lc src/plugin.zig -femit-bin=brainfuck.so
zlang module pack . -o brainfuck.zlx
echo "Built brainfuck.zlx"
