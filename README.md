# ONNX runtime on ROCm in NixOS

This is a fork of ONNX runtime in NixOS, which supports ROCm. Tested on AMD Raedon RX 6750 XT (gfx1030).

NixOS has a unique file system layout (/nix/store), so the build process is different from the other Linux distributions. Check flake.nix for details.

## Build

```bash
nix develop .
```

## TODO

1. Support ROCm 6
2. Support ONNX runtime 1.18

## Known issues

1. On AMD Ryzen 3600 (6 cores, 12 threads), it failed when compiling with 12 threads works with 6 threads.
2. Succeeding to 1., building with ninja failed, but it works with make.
3. Only release version works: https://github.com/llvm/llvm-project/issues/88497

## Reference

1. ONNX runtime in NixOS (CPU and CUDA): https://github.com/NixOS/nixpkgs/blob/nixos-24.05/pkgs/development/libraries/onnxruntime/default.nix#L107

2. Set ROCm device library for clang: https://github.com/ROCm/ROCm-Device-Libs/issues/81

3. Setup ROCm home in NixOS:
   - https://discourse.nixos.org/t/adding-a-symlink-or-extra-directory-indirection-for-a-package/38001
   - https://discourse.nixos.org/t/what-should-rocm-path-be/42396
