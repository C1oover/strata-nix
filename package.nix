{
  lib,
  cudaPackages,
  cmake,
  ninja,
  makeWrapper,
  autoAddDriverRunpath,
  python3,
  strataSrc,
  llamaSrc,
  # Default covers RTX 30xx (86) and RTX 40xx (89); override with e.g. "86" for faster builds
  cudaArchs ? "86-real;89-real;89-virtual",
  enableVision ? true,
}:

let
  versionLine = builtins.head (
    builtins.filter (l: builtins.match ".*project\\(strata VERSION.*" l != null)
      (lib.splitString "\n" (builtins.readFile "${strataSrc}/CMakeLists.txt"))
  );
  version = builtins.head (builtins.match ".*project\\(strata VERSION ([0-9.]+).*" versionLine);

  ggmlPin = builtins.head (
    builtins.match "([0-9a-f]+).*" (builtins.readFile "${strataSrc}/third_party/ggml/VERSION.txt")
  );

  _ =
    if (llamaSrc.rev or ggmlPin) == ggmlPin then
      true
    else
      throw "llama-cpp input (${llamaSrc.rev or "unknown"}) does not match Strata's third_party/ggml/VERSION.txt (${ggmlPin})";

  pythonEnv = python3.withPackages (ps: with ps; [
    numpy
    jinja2
    regex
    pyyaml
    tqdm
    requests
    pillow
    psutil
  ]);
in
cudaPackages.backendStdenv.mkDerivation {
  pname = "strata";
  inherit version;
  src = strataSrc;
  strictDeps = true;

  nativeBuildInputs = [
    cmake
    ninja
    makeWrapper
    cudaPackages.cuda_nvcc
    autoAddDriverRunpath
  ];

  buildInputs = [
    cudaPackages.cudatoolkit
    cudaPackages.cuda_cudart
    cudaPackages.libcublas
  ];

  dontUseCmakeConfigure = true;

  env = {
    CUDAToolkit_ROOT = "${cudaPackages.cudatoolkit}";
    CUDAToolkit_INCLUDE_ROOT = "${cudaPackages.cudatoolkit}";
    CUDAToolkit_LIBRARY_ROOT = "${cudaPackages.cudatoolkit}";
  };

  buildPhase = ''
    runHook preBuild

    # 1. Build main CUDA engine and K-quant kernel library (matching upstream Dockerfile)
    cmake -G Ninja -S . -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DSTRATA_ENABLE_CUDA=ON \
      -DSTRATA_BUILD_TESTS=OFF \
      -DSTRATA_NATIVE_EXPERTS=ON \
      -DSTRATA_PORTABLE=ON \
      -DSTRATA_Q6K_EXPERTS=ON \
      -DSTRATA_MMQ_KQUANTS=ON \
      -DCMAKE_CUDA_ARCHITECTURES="${cudaArchs}" \
      -DCMAKE_CUDA_COMPILER="${cudaPackages.cuda_nvcc}/bin/nvcc" \
      -DSTRATA_GGML_DIR="${llamaSrc}"

    ninja -C build -j"$NIX_BUILD_CORES" strata
    if ninja -C build -t targets all 2>/dev/null | grep -q "^strata_kq:"; then
      ninja -C build -j"$NIX_BUILD_CORES" strata_kq
    fi
    if ninja -C build -t targets all 2>/dev/null | grep -q "^strata-device:"; then
      ninja -C build -j"$NIX_BUILD_CORES" strata-device
    fi

    # 2. Build vision encoder (strata-vision) from tools/vision
    ${lib.optionalString enableVision ''
      if [[ -f tools/vision/CMakeLists.txt ]]; then
        cmake -G Ninja -S tools/vision -B build-vision \
          -DCMAKE_BUILD_TYPE=Release \
          -DLLAMA_DIR="${llamaSrc}" \
          -DSTRATA_VISION_CUDA=ON \
          -DSTRATA_PORTABLE=ON \
          -DGGML_CUDA_NCCL=OFF \
          -DCMAKE_CUDA_ARCHITECTURES="${cudaArchs}" \
          -DCMAKE_CUDA_COMPILER="${cudaPackages.cuda_nvcc}/bin/nvcc"
        ninja -C build-vision -j"$NIX_BUILD_CORES" strata-vision
      fi
    ''}

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/libexec/strata $out/share/strata

    # Copy compiled ELF binaries directly from build/ (never from source/bin/)
    install -Dm755 build/strata $out/libexec/strata/strata
    ln -s $out/libexec/strata/strata $out/bin/strata-engine

    if [[ -f build/libstrata_kq.so ]]; then
      install -Dm755 build/libstrata_kq.so $out/libexec/strata/libstrata_kq.so
    fi
    if [[ -f build/strata-device ]]; then
      install -Dm755 build/strata-device $out/libexec/strata/strata-device
      ln -s $out/libexec/strata/strata-device $out/bin/strata-device
    fi

    visionMode="none"
    if [[ -f build-vision/bin/strata-vision ]]; then
      install -Dm755 build-vision/bin/strata-vision $out/libexec/strata/strata-vision
      ln -s $out/libexec/strata/strata-vision $out/bin/strata-vision
      visionMode="gpu"
    elif [[ -f build-vision/strata-vision ]]; then
      install -Dm755 build-vision/strata-vision $out/libexec/strata/strata-vision
      ln -s $out/libexec/strata/strata-vision $out/bin/strata-vision
      visionMode="gpu"
    fi

    cat > $out/libexec/strata/BUILD.json <<EOF
{
  "version": "${version}",
  "source": "nix",
  "vision": "$visionMode"
}
EOF

    # Install Python server, packing tools, data profiles, and gguf-py
    cp -rL serve tools data chat.py $out/share/strata/
    chmod -R u+w $out/share/strata
    mkdir -p $out/share/strata/third_party/llama.cpp
    cp -rL ${llamaSrc}/gguf-py $out/share/strata/third_party/llama.cpp/gguf-py

    install -Dm755 ${./prepare.py} $out/share/strata/prepare.py

    makeWrapper ${pythonEnv}/bin/python $out/bin/strata-serve \
      --set STRATA_SHARE "$out/share/strata" \
      --set STRATA_GGUF_PY "$out/share/strata/third_party/llama.cpp/gguf-py" \
      --prefix PATH : "$out/libexec/strata" \
      --add-flags "$out/share/strata/serve/server.py"

    makeWrapper ${pythonEnv}/bin/python $out/bin/strata-prepare \
      --set STRATA_SHARE "$out/share/strata" \
      --set STRATA_ENGINE_DIR "$out/libexec/strata" \
      --set STRATA_GGUF_PY "$out/share/strata/third_party/llama.cpp/gguf-py" \
      --prefix PATH : "$out/libexec/strata" \
      --add-flags "$out/share/strata/prepare.py"

    makeWrapper ${pythonEnv}/bin/python $out/bin/strata-chat \
      --add-flags "$out/share/strata/chat.py"

    runHook postInstall
  '';

  passthru = {
    inherit pythonEnv cudaArchs enableVision;
  };

  meta = {
    description = "Strata inference engine and OpenAI/Anthropic-compatible server";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata-serve";
  };
}
