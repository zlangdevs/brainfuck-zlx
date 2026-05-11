# brainfuck.zlx

ZLang extension that adds `brainfuck { ... }` blocks to `.zl` source.

## Build

```sh
./build.sh
```

Produces `brainfuck.so` next to `brainfuck.zlx`. The `.so` is the
required install-time sidecar (same stem as the `.zlx`).

## Install

```sh
zlang install ./brainfuck.zlx
```

## Use

```zl
fun main() >> i32 {
    brainfuck {
        ++++++++[>++++++++<-]>+.
    }
    return 0;
}
```

The plugin's syntax-block handler translates the raw Brainfuck source
into inline ZLang statements operating on a 30000-cell `u8` tape.

## Status

First cut. Supports `+ - > < . [ ]`. `,` and cell-width selection
(`-b8`/`-b16`/`-b32`/`-b64`) are TODO. Targets `linux-x86_64`.
