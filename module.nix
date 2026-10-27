{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.strata;
  defaultPkg = self.packages.${pkgs.stdenv.hostPlatform.system}.strata;
in
{
  options.services.strata = {
    enable = lib.mkEnableOption "Strata local LLM inference server";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPkg;
      description = "The Strata package to use.";
    };

    repo = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF";
      description = "Hugging Face repository ID (`owner/name`).";
    };

    revision = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Hugging Face Git branch, tag, or commit revision.";
    };

    files = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "IQ2_XS/Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00001-of-00002.gguf"
        "IQ2_XS/Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-00002-of-00002.gguf"
      ];
      description = "List of GGUF file paths inside `repo` to download.";
    };

    modelPaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = "Local GGUF shard paths (used instead of `repo` and `files`).";
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "IQ2_XS";
      description = "Model/quantization tag used to name the prepared pack directory.";
    };

    modelName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional model name reported by `/v1/models`.";
    };

    mmprojRepo = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Hugging Face repo containing a vision `mmproj` GGUF.";
    };

    mmprojFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to the `mmproj` GGUF file inside `mmprojRepo`.";
    };

    mmprojPath = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Local path to a vision `mmproj` GGUF file.";
    };

    visionGpu = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the vision encoder (`strata-vision`) on the GPU (recommended for >=24 GB VRAM).";
    };

    mtp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the Multi-Token Prediction (MTP) speculative draft layer.";
    };

    lowRam = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Map expert weights from disk (`experts.bin`) instead of holding all experts in RAM.";
    };

    context = lib.mkOption {
      type = lib.types.ints.positive;
      default = 32768;
      description = "Maximum context length in tokens.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Listen address for the HTTP API.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Listen port for the HTTP API.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open `services.strata.port` in the firewall.";
    };

    gpus = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "CUDA GPU indices (PCI bus order). Empty automatically picks the largest GPU.";
    };

    lazyLoad = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start the HTTP server immediately and load model weights on the first request.";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file containing the API key.";
    };

    hfTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file containing a Hugging Face access token.";
    };

    sampling = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = { temperature = 1.0; top_p = 0.95; top_k = 20; };
      description = "Default sampling parameters.";
    };

    extraEngineArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--kv-streaming" "on" "--kv-grow" "--resident-experts" ];
      description = "Extra CLI arguments appended to the Strata engine invocation.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.repo != null && cfg.files != [ ]) || cfg.modelPaths != [ ];
        message = "services.strata: set either (`repo` and `files`) or `modelPaths`.";
      }
      {
        assertion = cfg.host == "127.0.0.1" || cfg.host == "localhost" || cfg.apiKeyFile != null;
        message = "services.strata: binding beyond loopback requires `apiKeyFile`.";
      }
    ];

    systemd.services.strata = {
      description = "Strata Local LLM Inference Server";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      environment = lib.optionalAttrs (cfg.gpus != [ ]) {
        CUDA_DEVICE_ORDER = "PCI_BUS_ID";
        CUDA_VISIBLE_DEVICES = lib.concatStringsSep "," cfg.gpus;
      };

      preStart = toString (pkgs.writeShellScript "strata-prestart" (''
        set -euo pipefail
        exec ${cfg.package}/bin/strata-prepare \
          --data-dir "$STATE_DIRECTORY" \
          --emit-config "$STATE_DIRECTORY/config.json" \
          --model ${lib.escapeShellArg cfg.model} \
          --mtp ${if cfg.mtp then "on" else "off"} \
          --context ${toString cfg.context} \
          --host ${lib.escapeShellArg cfg.host} \
          --port ${toString cfg.port} \
      '' + lib.optionalString (cfg.repo != null) ''
          --repo ${lib.escapeShellArg cfg.repo} \
          --revision ${lib.escapeShellArg cfg.revision} \
      '' + lib.concatMapStrings (f: ''--file ${lib.escapeShellArg f} '') cfg.files
         + lib.concatMapStrings (p: ''--model-path ${lib.escapeShellArg (toString p)} '') cfg.modelPaths
         + lib.optionalString (cfg.modelName != null) ''
          --model-name ${lib.escapeShellArg cfg.modelName} \
      '' + lib.optionalString (cfg.mmprojRepo != null && cfg.mmprojFile != null) ''
          --mmproj-repo ${lib.escapeShellArg cfg.mmprojRepo} \
          --mmproj-file ${lib.escapeShellArg cfg.mmprojFile} \
      '' + lib.optionalString (cfg.mmprojPath != null) ''
          --mmproj-path ${lib.escapeShellArg (toString cfg.mmprojPath)} \
      '' + lib.optionalString cfg.visionGpu ''
          --vision-gpu \
      '' + lib.optionalString cfg.lowRam ''
          --low-ram \
      '' + lib.optionalString cfg.lazyLoad ''
          --lazy \
      '' + lib.optionalString (cfg.gpus != [ ]) ''
          --gpu ${lib.escapeShellArg (lib.concatStringsSep "," cfg.gpus)} \
      '' + lib.optionalString (cfg.apiKeyFile != null) ''
          --api-key-file "/run/credentials/strata.service/api-key" \
      '' + lib.optionalString (cfg.hfTokenFile != null) ''
          --hf-token-file "/run/credentials/strata.service/hf-token" \
      '' + lib.optionalString (cfg.sampling != { }) ''
          --sampling-json ${pkgs.writeText "strata-sampling.json" (builtins.toJSON cfg.sampling)} \
      '' + lib.concatMapStrings (x: ''--extra-arg ${lib.escapeShellArg x} '') cfg.extraEngineArgs
      ));

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        SupplementaryGroups = [ "video" "render" ];
        StateDirectory = "strata";
        StateDirectoryMode = "0750";
        WorkingDirectory = "%S/strata";
        TimeoutStartSec = "0";
        Restart = "on-failure";
        RestartSec = 10;

        # Pinned host memory (cudaHostAlloc/mlock) and real-time worker threads
        LimitMEMLOCK = "infinity";
        LimitRTTIME = "infinity";

        LoadCredential =
          lib.optional (cfg.apiKeyFile != null) "api-key:${cfg.apiKeyFile}"
          ++ lib.optional (cfg.hfTokenFile != null) "hf-token:${cfg.hfTokenFile}";

        ExecStart = "${cfg.package}/bin/strata-serve --engine strata --config %S/strata/config.json --port ${toString cfg.port}";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = false;
        DeviceAllow = [
          "/dev/nvidiactl rw"
          "/dev/nvidia-uvm rw"
          "/dev/nvidia-uvm-tools rw"
          "/dev/nvidia-modeset rw"
          "char-nvidia-frontend rw"
          "char-drm rw"
        ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = false;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
