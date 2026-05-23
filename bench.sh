#!/bin/sh
set -e
cd "$(dirname "$0")"
ZLANG=../zlang/zig-out/bin/zlang
ZLB_DIR=../zlb
BUILD_DIR=/tmp/bf-bench
mkdir -p "$BUILD_DIR"

run_bench() {
    name="$1"; src="$2"; bits="${3:-32}"
    bin="$BUILD_DIR/${name}.bin"
    bfsrc="$BUILD_DIR/${name}.b.zl"
    case "${src##*.}" in
        bf|b) cp "$src" "$BUILD_DIR/${name}.b" ;;
        zlb) "$ZLANG" "$src" -o "$BUILD_DIR/${name}.b" >/dev/null 2>&1 ;;
    esac
    bytes=$(stat -c %s "$BUILD_DIR/${name}.b")
    printf 'fun main() >> i32 {\nbrainfuck {\n?cell_size %s?\n?len 30000?\n' "$bits" > "$bfsrc"
    cat "$BUILD_DIR/${name}.b" >> "$bfsrc"
    printf '\n}\nreturn 0;\n}\n' >> "$bfsrc"
    c_start=$(date +%s%N)
    "$ZLANG" "$bfsrc" -o "$bin" >/dev/null 2>&1
    c_end=$(date +%s%N)
    cms=$(( (c_end - c_start) / 1000000 ))
    r_start=$(date +%s%N)
    "$bin" >/dev/null 2>&1 || true
    r_end=$(date +%s%N)
    rms=$(( (r_end - r_start) / 1000000 ))
    bs=$(stat -c %s "$bin")
    printf "%-12s  bf=%-10s  bin=%-8s  compile=%5dms  run=%5dms\n" "$name" "$bytes" "$bs" "$cms" "$rms"
}

echo "=== bf.zlx benchmark $(date +%H:%M:%S) ==="
run_bench mandelbrot ../zlang/thirdparties/mandelbrot.bf 32
run_bench sieve100 $ZLB_DIR/examples/bench_sieve.zlb 64
