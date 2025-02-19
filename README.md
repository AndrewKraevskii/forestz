# forestz 🌳🌲🌿⚡

Util to count lines of code but with inclusion of dependencies.

## Building:

```sh
git clone https://github.com/andrewkraevskii/forsetz
cd forestz
zig build run -- /path/to/project
```

## If you want fast version
```sh
zig build -Duse-llvm -Doptimize=ReleaseFast
./zig-out/bin/forestz /path/to/project
```



## Supported languages:
- zig

## Planned languages:
- rust
- go
- js (node/deno/bun)


## TODO
- [ ] Nicer ui for case of printing lines for projects but not lines.
- [ ] sort projects by lines not just files inside of them.
- [ ] show lines like graph dust-du style.
- [ ] Multithreading? Probably not to hard but its pretty fast as is.
