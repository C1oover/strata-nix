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
      description = "Run the vision encoder (`strata-vision`) on the GPU.";
    };

    mtp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the Multi-Token Prediction (MTP) speculative draft layer.";
    };

    lowRam = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Build `experts.bin` and enable `--resident-experts` (page-locks non-GPU experts in RAM with a 4 GiB safety floor and mmaps the rest).";
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
      description = "Start the HTTP server immediately and load model weights on the first request (`--lazy`).";
    };

    idleUnload = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      example = 600;
      description = "Unload the model after this many seconds without requests (`--idle-unload`).";
    };

    minFreeVramMib = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      example = 16384;
      description = "Load an unloaded model only when this much VRAM (MiB) is free, else answer HTTP 503 (`--min-free-vram-mib`).";
    };

    beforeLoad = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Command run before the model is loaded into VRAM (`--before-load`).";
    };

    parallel = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Number of simultaneous engine slots (`--parallel`).";
    };

    batchGroups = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Pipeline groups for batching: `auto` or a positive integer (`--batch-groups`).";
    };

    maxQueue = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = "Maximum inference calls waiting beyond effective engine slots; 0 refuses overload (`--max-queue`).";
    };

    queueTimeout = lib.mkOption {
      type = lib.types.nullOr lib.types.number;
      default = null;
      description = "Maximum seconds waiting for the first engine turn (`--queue-timeout`).";
    };

    shutdownTimeout = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = "Graceful drain deadline in seconds (0..300) before active requests are cancelled (`--shutdown-timeout`).";
    };

    slotSavePath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Directory for saving/restoring conversation slots via POST /slots/0 (`--slot-save-path`).";
    };

    fitMaxTokens = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Clamp max_tokens to remaining context instead of rejecting with HTTP 400 (`--fit-max-tokens` / `--no-fit-max-tokens`).";
    };

    apiMonitor = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable `/api-monitor` keeping the last 100 requests in memory (`--api-monitor`).";
    };

    offline = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Do not fetch remote image URLs or start MCP/tool subprocesses (`--offline`).";
    };

    noApiKey = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Serve on the network without an API key (`--no-api-key`).";
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

    extraConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = { allowed_hosts = [ "strata.local" ]; };
      description = "Freeform JSON attributes merged into the top level of `config.json`.";
    };

    extraEngineArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--vram-reserve-mib" "2000" ];
      description = "Freeform CLI arguments appended to the C++ `strata` engine invocation.";
    };

    extraServeArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--batch-telemetry" ];
      description = "Freeform CLI arguments appended to `strata-serve` (`serve/server.py`).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.repo != null && cfg.files != [ ]) || cfg.modelPaths != [ ];
        message = "services.strata: set either (`repo` and `files`) or `modelPaths`.";
      }
      {
        assertion = cfg.host == "127.0.0.1" || cfg.host == "localhost" || cfg.apiKeyFile != null || cfg.noApiKey;
        message = "services.strata: binding beyond loopback requires `apiKeyFile` or `noApiKey = true`.";
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
      '' + lib.optionalString (cfg.extraConfig != { }) ''
          --extra-config-json ${pkgs.writeText "strata-extra-config.json" (builtins.toJSON cfg.extraConfig)} \
      '' + lib.concatMapStrings (x: ''--extra-arg=${lib.escapeShellArg x} '') cfg.extraEngineArgs
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

        ExecStart = lib.concatStringsSep " " (
          [
            "${cfg.package}/bin/strata-serve"
            "--engine" "strata"
            "--config" "%S/strata/config.json"
            "--host" (lib.escapeShellArg cfg.host)
            "--port" (toString cfg.port)
          ]
          ++ lib.optional cfg.lazyLoad "--lazy"
          ++ lib.optionals (cfg.idleUnload != null) [ "--idle-unload" (toString cfg.idleUnload) ]
          ++ lib.optionals (cfg.minFreeVramMib != null) [ "--min-free-vram-mib" (toString cfg.minFreeVramMib) ]
          ++ lib.optionals (cfg.beforeLoad != null) [ "--before-load" (lib.escapeShellArg cfg.beforeLoad) ]
          ++ lib.optionals (cfg.parallel != null) [ "--parallel" (toString cfg.parallel) ]
          ++ lib.optionals (cfg.batchGroups != null) [ "--batch-groups" (lib.escapeShellArg cfg.batchGroups) ]
          ++ lib.optionals (cfg.maxQueue != null) [ "--max-queue" (toString cfg.maxQueue) ]
          ++ lib.optionals (cfg.queueTimeout != null) [ "--queue-timeout" (toString cfg.queueTimeout) ]
          ++ lib.optionals (cfg.shutdownTimeout != null) [ "--shutdown-timeout" (toString cfg.shutdownTimeout) ]
          ++ lib.optionals (cfg.slotSavePath != null) [ "--slot-save-path" (lib.escapeShellArg cfg.slotSavePath) ]
          ++ [ (if cfg.fitMaxTokens then "--fit-max-tokens" else "--no-fit-max-tokens") ]
          ++ lib.optional cfg.apiMonitor "--api-monitor"
          ++ lib.optional cfg.offline "--offline"
          ++ lib.optional cfg.noApiKey "--no-api-key"
          ++ map lib.escapeShellArg cfg.extraServeArgs
        );

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = false;
        DeviceAllow = [
          "/dev/nvidia0 rw"
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
