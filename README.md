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



## Supported build systems:
- build zig

## Planned build systems:
- cargo (rust)
- go
- node/deno/bun (js)

## TODO
- [ ] avoid counting same files twice for dependenices inside of directory.
- [ ] add directory's filtering options.
- [ ] add language filtering options.
- [ ] sort also languages.
- [ ] comment detection for non zig not working.
- [ ] use rich text output for better visual clarity.
- [ ] sort projects by lines not just files inside of them.
- [ ] show lines like graph dust-du style.
- [ ] Multithreading? Probably not to hard but its pretty fast as is.
