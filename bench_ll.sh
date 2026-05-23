#!/bin/sh
# Compare zlang-text emit (brainfuck {} wrap) vs direct-LLVM-IR (.b file extension)
set -e
cd "$(dirname "$0")"
ZLANG=../zlang/zig-out/bin/zlang
ZLB_DIR=../zlb
BUILD_DIR=/tmp/bf-bench-ll
mkdir -p "$BUILD_DIR"
rm -f "$BUILD_DIR"/*

bench_one() {
    name="$1"; src="$2"; bits="${3:-32}"
    case "${src##*.}" in
        bf|b) cp "$src" "$BUILD_DIR/${name}.b" ;;
        zlb) "$ZLANG" "$src" -o "$BUILD_DIR/${name}.b" >/dev/null 2>&1 ;;
    esac

    # Path A: wrapped .zl with brainfuck {} block (existing syntax-block backend)
    wrap="$BUILD_DIR/${name}.b.zl"
    printf 'fun main() >> i32 {\nbrainfuck {\n?cell_size %s?\n?len 30000?\n' "$bits" > "$wrap"
    cat "$BUILD_DIR/${name}.b" >> "$wrap"
    printf '\n}\nreturn 0;\n}\n' >> "$wrap"
    binA="$BUILD_DIR/${name}.A.bin"
    sA=$(date +%s%N); "$ZLANG" "$wrap" -o "$binA" >/dev/null 2>&1; eA=$(date +%s%N)
    cAms=$(( (eA - sA) / 1000000 ))
    rA1=$(date +%s%N); "$binA" >/dev/null 2>&1 || true; rA2=$(date +%s%N)
    rAms=$(( (rA2 - rA1) / 1000000 ))
    bsA=$(stat -c %s "$binA")

    # Path B: direct .b → clang -x ir → obj → link (new file-extension backend, v5 API)
    binB="$BUILD_DIR/${name}.B.bin"
    case "$bits" in
        8|16|32|64) bflag="-b${bits}" ;;
        *) bflag="-b8" ;;
    esac
    sB=$(date +%s%N); "$ZLANG" "$bflag" "$BUILD_DIR/${name}.b" -c -o "$binB" >/dev/null 2>&1; eB=$(date +%s%N)
    cBms=$(( (eB - sB) / 1000000 ))
    rB1=$(date +%s%N); "$binB" >/dev/null 2>&1 || true; rB2=$(date +%s%N)
    rBms=$(( (rB2 - rB1) / 1000000 ))
    bsB=$(stat -c %s "$binB")

    printf "%-12s  A: comp=%5dms run=%5dms bin=%-7s   B: comp=%5dms run=%5dms bin=%-7s\n" \
        "$name" "$cAms" "$rAms" "$bsA" "$cBms" "$rBms" "$bsB"
}

echo "=== A=zlang-text wrap  B=direct LLVM IR  ($(date +%H:%M:%S)) ==="
bench_one mandelbrot ../zlang/thirdparties/mandelbrot.bf 32
bench_one sieve100   $ZLB_DIR/examples/bench_sieve.zlb 64
bench_one loops      $ZLB_DIR/examples/bench_loops.zlb 64
bench_one fib        $ZLB_DIR/examples/bench_fib.zlb 64
