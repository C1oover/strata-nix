#!/usr/bin/env python3
"""Agnostic model preparation and config generator for Strata on NixOS."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

SHARE = Path(os.environ["STRATA_SHARE"])
ENGINE_DIR = Path(os.environ["STRATA_ENGINE_DIR"])
TOOLS = SHARE / "tools"
sys.path.insert(0, str(TOOLS))


def log(msg: str) -> None:
    print(f"[strata-prepare] {msg}", flush=True)


def die(msg: str) -> None:
    print(f"[strata-prepare] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def slugify(text: str) -> str:
    return re.sub(r"[^a-zA-Z0-9._-]+", "-", text).strip("-").lower()


def hf_url(repo: str, revision: str, filename: str) -> str:
    rev = urllib.parse.quote(revision, safe="")
    path = "/".join(urllib.parse.quote(p, safe="") for p in filename.split("/"))
    return f"https://huggingface.co/{repo}/resolve/{rev}/{path}"


def download_file(url: str, dst: Path, token: str | None = None) -> None:
    done_marker = dst.with_name(dst.name + ".done")
    if dst.exists() and done_marker.exists():
        log(f"already present: {dst.name}")
        return

    dst.parent.mkdir(parents=True, exist_ok=True)
    headers = {"User-Agent": "strata-nixos"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    total = 0
    req = urllib.request.Request(url, method="HEAD", headers=headers)
    with urllib.request.urlopen(req, timeout=60) as resp:
        total = int(resp.headers.get("Content-Length", 0))

    if dst.exists() and total and dst.stat().st_size == total:
        done_marker.write_text(time.strftime("%Y-%m-%d %H:%M\n"), encoding="utf-8")
        log(f"already present (size verified): {dst.name}")
        return

    part = dst.with_name(dst.name + ".part")
    have = part.stat().st_size if part.exists() else 0

    for attempt in range(30):
        try:
            req_headers = {**headers, "Range": f"bytes={have}-"} if have else headers
            req = urllib.request.Request(url, headers=req_headers)
            with urllib.request.urlopen(req, timeout=120) as r, open(part, "ab" if have else "wb") as f:
                if have and r.status != 206:
                    f.seek(0)
                    f.truncate()
                    have = 0
                last_log = 0.0
                while chunk := r.read(8 << 20):
                    f.write(chunk)
                    have += len(chunk)
                    if time.time() - last_log > 10:
                        last_log = time.time()
                        pct = f" ({100 * have / total:.0f}%)" if total else ""
                        log(f"downloading {dst.name}: {have / 1e9:.2f} / {total / 1e9:.2f} GB{pct}")
            if not total or have >= total:
                break
        except OSError as err:
            log(f"download interrupted ({err}), retrying in 10s...")
            time.sleep(10)

    if total and part.stat().st_size != total:
        die(f"incomplete download for {dst.name}")

    part.replace(dst)
    done_marker.write_text(time.strftime("%Y-%m-%d %H:%M\n"), encoding="utf-8")
    log(f"downloaded: {dst.name}")


def verify_gguf_and_find_ple(shards: list[Path]) -> Path | None:
    import gguf_reader as G

    ple_shard: Path | None = None
    for s in shards:
        if not s.exists():
            die(f"missing GGUF file: {s}")
        try:
            g = G.GGUFFile(s)
        except (ValueError, struct.error) as err:
            die(f"corrupt GGUF header in {s.name}: {err}")
        if any(t.name == "per_layer_token_embd.weight" for t in g.tensors):
            ple_shard = s
    return ple_shard


def run_tool(script: str, *args: str | Path) -> None:
    cmd = [sys.executable, str(TOOLS / script), *(str(a) for a in args)]
    log("running: " + " ".join(cmd[1:]))
    res = subprocess.run(cmd)
    if res.returncode != 0:
        die(f"{script} exited with code {res.returncode}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--emit-config", required=True)
    ap.add_argument("--repo", help="Hugging Face repo ID (owner/name)")
    ap.add_argument("--revision", default="main")
    ap.add_argument("--file", action="append", default=[], help="GGUF file(s) in --repo")
    ap.add_argument("--model-path", action="append", default=[], help="Local GGUF file path(s)")
    ap.add_argument("--model", default="custom", help="Quantization/model tag used for pack naming")
    ap.add_argument("--model-name", help="Served model name in API responses")
    ap.add_argument("--mmproj-repo")
    ap.add_argument("--mmproj-file")
    ap.add_argument("--mmproj-path")
    ap.add_argument("--vision-gpu", action="store_true", help="Run vision encoder on GPU instead of CPU")
    ap.add_argument("--mtp", choices=["on", "off"], default="on")
    ap.add_argument("--low-ram", action="store_true")
    ap.add_argument("--expert-profile", default="expert-profile.bin")
    ap.add_argument("--context", type=int, default=32768)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--gpu")
    ap.add_argument("--lazy", action="store_true")
    ap.add_argument("--api-key-file")
    ap.add_argument("--hf-token-file")
    ap.add_argument("--sampling-json")
    ap.add_argument("--extra-arg", action="append", default=[])
    a = ap.parse_args()

    data_dir = Path(a.data_dir)
    token = None
    if a.hf_token_file and Path(a.hf_token_file).exists():
        token = Path(a.hf_token_file).read_text(encoding="utf-8").strip() or None

    # 1. Acquire model shards
    shards: list[Path] = []
    if a.model_path:
        shards = [Path(p) for p in a.model_path]
        tag = slugify(f"{shards[0].stem}-{a.model}")
    elif a.repo and a.file:
        repo_slug = slugify(a.repo)
        tag = slugify(f"{a.repo.split('/')[-1]}-{a.model}")
        for f in a.file:
            dst = data_dir / "models" / repo_slug / f
            download_file(hf_url(a.repo, a.revision, f), dst, token=token)
            shards.append(dst)
    else:
        die("specify either (--repo and --file) or --model-path")

    shard1 = shards[0]
    ple_shard = verify_gguf_and_find_ple(shards)

    # 2. Build Strata Pack (if model uses Qwen3.8 PLE / MoE layout) or run direct GGUF
    args: list[str] = []
    tokenizer_dir: str | None = None

    if ple_shard is not None:
        pack_dir = data_dir / "packs" / tag
        if not (pack_dir / "native_experts.txt").exists() or not (pack_dir / "tokenizer" / "vocab.json").exists():
            log(f"packing model into {pack_dir} ...")
            run_tool("iq_pack.py", "--gguf", shard1, "--out", pack_dir, "--compat-bf16")
        else:
            log(f"pack already built: {pack_dir}")

        needs_experts_bin = a.low_ram or any(
            x in ("--resident-experts", "--mmap-experts", "--resident-cpu-experts") for x in a.extra_arg
        )
        if needs_experts_bin and not (pack_dir / "experts.bin").exists():
            log("building experts.bin for resident/mmap expert mode ...")
            run_tool("iq_pack.py", "--gguf", shard1, "--out", pack_dir, "--compat-bf16", "--experts-bin")

        if a.low_ram and not (pack_dir / "experts.bin").exists():
            log("building experts.bin for low-RAM mmap mode ...")
            run_tool("iq_pack.py", "--gguf", shard1, "--out", pack_dir, "--compat-bf16", "--experts-bin")

        args += [
            "--pack", str(pack_dir),
            "--native", str(shard1),
            "--ple-gguf", str(ple_shard),
        ]
        prof = SHARE / "data" / a.expert_profile
        if prof.exists():
            args += ["--expert-profile", str(prof)]
        args += ["--expert-cache", "auto", "--prefill", "auto"]
        if a.low_ram:
            args += ["--mmap-experts"]
        tokenizer_dir = str(pack_dir / "tokenizer")
    else:
        args += ["--model", str(shard1)]

    # 3. Prepare MTP draft layer
    if a.mtp == "on" and ple_shard is not None:
        mtp_dir = data_dir / "mtp"
        rt_dir = mtp_dir / "rt"
        if not (rt_dir / "experts.bin").exists():
            log("fetching and packing MTP draft layer (~5 GB) ...")
            run_tool("mtp_fetch.py", "fetch", "--out", mtp_dir)
            run_tool("mtp_pack.py", "--src", mtp_dir, "--experts", "q2_0", "--out", mtp_dir / "mtp-q2_0.gguf")
            run_tool("mtp_rt.py", "--gguf", mtp_dir / "mtp-q2_0.gguf", "--out", rt_dir)
        vocab_src = SHARE / "data" / "draft_vocab.bin"
        if vocab_src.exists() and not (rt_dir / "draft_vocab.bin").exists():
            shutil.copyfile(vocab_src, rt_dir / "draft_vocab.bin")
        args += ["--spec", "4", "--spec-min-p", "0.5", "--mtp", str(rt_dir)]

    # 4. Optional Vision (mmproj)
    vision_cfg: dict | None = None
    mmproj_file: Path | None = None
    if a.mmproj_path:
        mmproj_file = Path(a.mmproj_path)
    elif a.mmproj_repo and a.mmproj_file:
        mmproj_file = data_dir / "models" / slugify(a.mmproj_repo) / a.mmproj_file
        download_file(hf_url(a.mmproj_repo, a.revision, a.mmproj_file), mmproj_file, token=token)

    if mmproj_file is not None:
        vision_exe = ENGINE_DIR / "strata-vision"
        if not vision_exe.exists():
            die(f"vision requested, but {vision_exe} was not built")
        vision_cfg = {
            "exe": str(vision_exe),
            "mmproj": str(mmproj_file),
            "model": str(shard1),
            "gpu": bool(a.vision_gpu),
            "max_tokens": 300,
            "threads": 8,
        }
        if a.vision_gpu:
            args += ["--vram-reserve-mib", "700"]

    # 5. Context and extra arguments
    args += ["--max-context", str(a.context)]
    if a.context >= 65536 and not a.low_ram and "--kv-resident" not in a.extra_arg:
        args += ["--kv-resident", "32768"]
    if a.context > 262144 and "--rope-scaling" not in a.extra_arg:
        args += ["--rope-scaling", "yarn", "--rope-scale", f"{a.context / 262144:g}"]
    args += a.extra_arg

    # 6. Emit server config.json
    model_name = a.model_name or tag
    cfg: dict = {
        "exe": str(ENGINE_DIR / "strata"),
        "args": args,
        "model_name": model_name,
        "host": a.host,
        "port": a.port,
        "log": str(data_dir / f"engine-{tag}.log"),
    }
    if tokenizer_dir:
        cfg["tokenizer"] = tokenizer_dir
    if vision_cfg:
        cfg["vision"] = vision_cfg
    if a.gpu:
        cfg["gpu"] = a.gpu
    if a.lazy:
        cfg["lazy_load"] = True
    if a.api_key_file and Path(a.api_key_file).exists():
        key = Path(a.api_key_file).read_text(encoding="utf-8").strip()
        if key:
            cfg["api_key"] = key
    if a.sampling_json:
        cfg["sampling"] = json.loads(Path(a.sampling_json).read_text(encoding="utf-8"))

    out_path = Path(a.emit_config)
    out_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    if "api_key" in cfg:
        os.chmod(out_path, stat.S_IRUSR | stat.S_IWUSR)
    log(f"wrote server configuration: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
