# brainfuck.zlx

ZLang extension that adds `brainfuck { ... }` blocks to `.zl` source.

## Build

```sh
./build.sh
```

Compiles `src/plugin.zig` into `brainfuck.so`, then packs
`manifest.zon` + `brainfuck.so` into a single-file archive
`brainfuck.zlx`. Both intermediates are gitignored; only sources
(`manifest.zon`, `src/`, `examples/`, `build.sh`) are committed.

## Install

```sh
zlang module install ./brainfuck.zlx
```

## Use

```zl
fun main() >> i32 {
    brainfuck {
        ?len 30000?
        ++++++++[>++++++++<-]>+.
    }
    return 0;
}
```

Inside the block:
- `?len N?` — tape length.
- `?cell_size N?` — cell width in bits (8, 16, 32, 64).
- `?load name pos?` — copy a zlang `i32` variable into the tape at
  `pos`, write back on exit. Use `?load name:type pos?` to specify
  any iN / uN type (split big-endian across cells if it doesn't fit).
- `?? ...` — comment until end of line.

Standalone `.b` / `.bf` files compile with `zlang -bN file.bf`
(N = 8, 16, 32, 64) once the extension is installed.

## Optimizations

Done at codegen time (compile fragment is plain `.zl` so LLVM
optimizes the rest):
- Run-length contraction of `+ -` and `> <`.
- `[+]` / `[-]` → set cell to 0.
- `[<]` / `[>]` → scan loop.
- Linear loops like `[->++<]` → direct multiply-and-zero.
- Pointer-offset accumulation across non-IO ops.
- Dead-loop elimination after known-zero cells.

See `examples/` for hello world, variable load, and a calculator.
