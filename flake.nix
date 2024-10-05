{
  description = "A Nix-flake-based Python development environment";

  inputs.nixpkgs.url = "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/nixos-24.05/nixexprs.tar.xz";
  nixConfig.substituters = [
    "https://mirror.sjtu.edu.cn/nix-channels/store"
    "https://mirrors.ustc.edu.cn/nix-channels/store"
    "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
    "https://cache.nixos.org"
  ];

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forEachSupportedSystem = f: nixpkgs.lib.genAttrs supportedSystems (system: f {
        pkgs = import nixpkgs { inherit system; };
      });
    in
    {
      devShells = forEachSupportedSystem ({ pkgs }: {
        default = pkgs.mkShell rec {
          rocm_home = pkgs.symlinkJoin {
            name = "rocm-home";

            paths = [
              pkgs.rocmPackages_5.clr
              pkgs.rocmPackages_5.rocm-core
            ];

            postBuild = ''
              ln -s ${pkgs.rocmPackages_5.llvm.clang} $out/llvm
            '';
          };
          nativeBuildInputs = with pkgs; [
            rocmPackages_5.rocm-smi
            rocmPackages_5.rocminfo
            rocmPackages_5.llvm.rocmClangStdenv
            rocmPackages_5.llvm.bintools
            rocmPackages_5.llvm.clang
            rocmPackages_5.hipblas
            rocmPackages_5.hipify
            rocmPackages_5.hipcc
            rocmPackages_5.hipsolver
            rocmPackages_5.hip-common
            rocmPackages_5.hiprand
            rocmPackages_5.hipfft
            rocmPackages_5.hipsparse
            rocmPackages_5.hipcub
            rocmPackages_5.clr
            rocmPackages_5.rccl
            rocmPackages_5.rocm-runtime
            rocmPackages_5.rocm-device-libs
            rocmPackages_5.rocm-cmake
            rocmPackages_5.rocblas
            rocmPackages_5.roctracer
            rocmPackages_5.rocprim
            rocmPackages_5.rocthrust
            rocmPackages_5.miopen
            rocmPackages_5.miopengemm
            rocmPackages_5.migraphx
            cmake
            abseil-cpp
            ninja
            protobuf_21
          ];
          venvDir = ".venv";
          packages = with pkgs; [ python311 ] ++
            (with pkgs.python311Packages; [
              pip
              venvShellHook
              numpy
              onnx
              packaging
              setuptools
              wheel
            ]);
          env.NIX_CFLAGS_COMPILE = toString [
            "-Wno-error=deprecated-declarations"
            "-Wno-error=unused-but-set-variable"
            "-Wno-error=unused-parameter"
            "-Wno-error=overloaded-virtual"
          ];
          shellHook = with pkgs; ''
            export ROCM_PATH="${rocm_home}"
            export MIOPEN_PATH="${rocmPackages_5.miopen}"
            export MIGRAPHX_PATH="${rocmPackages_5.migraphx}"
            export ROCM_DEVICE_LIB_PATH="${rocmPackages_5.rocm-device-libs}"
            export HIP_DEVICE_LIB_PATH="${rocmPackages_5.rocm-device-libs}/amdgcn/bitcode"
            export DEVICE_LIB_PATH="${rocmPackages_5.rocm-device-libs}/amdgcn/bitcode"
            export ABSL_PATH="${abseil-cpp.src}"
            export HSA_OVERRIDE_GFX_VERSION=10.3.0
            export HCC_AMDGPU_TARGET=gfx1030
            sh ./build.sh --update --build --build_wheel --config Release --use_migraphx --migraphx_home $MIGRAPHX_PATH --rocm_home $ROCM_PATH --cmake_extra_defines FETCHCONTENT_SOURCE_DIR_ABSEIL_CPP=$ABSL_PATH CMAKE_HIP_ARCHITECTURES=gfx1030 --parallel 6
          '';
        };
      });
    };
}
