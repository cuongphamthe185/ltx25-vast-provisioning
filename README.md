# LTX / MiniMax H3 ComfyUI provisioning for Vast.ai

Provisioning script for a Vast.ai instance running the `vastai/comfy:v0.42.1` image
(`-cuda-12.9-py312` or `-cuda-13.2-py312`, see [Choosing the image](#choosing-the-image)).
`DONUT_MODEL` picks which model set it installs into ComfyUI.

## Model sets (`DONUT_MODEL`)

| Value | Model | Size | HF token |
|---|---|---|---|
| `ltx23` (default) | LTX-2.3 IC-LoRA Union Control, fp8, plus the video-to-video LoRAs picked with `DONUT_LORAS` | ~42 GB + LoRAs | Only for gated LoRAs |
| `ltx25` | LTX-2.5 video-to-video with IC-LoRAs (Layout-to-Render, Union Control), int8 | ~42 GB | Required (gated) |
| `h3` | MiniMax H3 text/image-to-video with audio, pruned int8 | ~44 GB (+23 GB with `DONUT_H3_R2V=1`) | Not needed |

### `ltx25`

| Type | File | Source repo |
|---|---|---|
| Diffusion model | `ltx-2.5-22b-distilled-transformer-comfy-int8-convrot` | Lightricks/LTX-2.5 (gated) |
| Text encoder | `gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot` | Lightricks/LTX-2.5 (gated) |
| VAE | `ltx-2.5-video-vae-bf16`, `ltx-2.5-audio-vae-bf16` | Lightricks/LTX-2.5 (gated) |
| Latent upscaler | `ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0` | Lightricks/LTX-2.5 (gated) |
| IC-LoRA | `ltx-2.5-22b-ic-lora-layout-to-render-1.0` | Lightricks/LTX-2.5-22b-IC-LoRA-Layout-To-Render (gated) |
| IC-LoRA | `ltx-2.3-22b-ic-lora-union-control-ref0.5` | Lightricks/LTX-2.3-22b-IC-LoRA-Union-Control |

It also downloads the official `LTX-2.5_ICLoRA_Layout_To_Render_Two_Stage_Distilled.json` workflow and
rewrites the model names to the int8 files above (`LTX-2.5_ICLoRA_Layout_To_Render_int8.json`).

### `ltx23`

The files of ComfyUI's LTX-2.3 IC-LoRA Union Control template, plus the spatial upscaler.

| Type | File | Folder | Source repo |
|---|---|---|---|
| Checkpoint | `ltx-2.3-22b-distilled-fp8` (29.5 GB) | `checkpoints` | Lightricks/LTX-2.3-fp8 |
| Text encoder | `gemma_3_12B_it_fp4_mixed` (9.45 GB) | `text_encoders` | Comfy-Org/ltx-2 |
| LoRA | `gemma-3-12b-it-abliterated_lora_rank64_bf16` | `loras` | Comfy-Org/ltx-2 |
| IC-LoRA | `ltx-2.3-22b-ic-lora-union-control-ref0.5` | `loras` | Lightricks/LTX-2.3-22b-IC-LoRA-Union-Control |
| Geometry | `moge_2_vitl_normal_fp16` | `geometry_estimation` | Comfy-Org/MoGe |
| Latent upscaler | `ltx-2.3-spatial-upscaler-x2-1.1` | `latent_upscale_models` | Lightricks/LTX-2.3 |

Use the workflows from ComfyUI's Template Library (Video → LTX-2.3). The FLF2V and IC-LoRA templates use this
checkpoint; the T2V/I2V templates expect `ltx-2.3-22b-dev-fp8` plus the distilled LoRA, which are not downloaded.

#### Video-to-video LoRAs (`DONUT_LORAS`)

Comma-separated keys, `all` or `none`; default `motion-track`. Only used with `DONUT_MODEL=ltx23`.
Gated LoRAs need `HF_TOKEN` from an account that accepted the license on each repo page; without it they show up
as `FAIL` lines and the run ends `FAILED`. All go to `models/loras`; bundled workflows go to the workflow list.
Most IC-LoRAs are wired with the IC-LoRA video-to-video workflows of ComfyUI-LTXVideo
(`LTXICLoRALoaderModelOnly` + `LTXAddVideoICLoRAGuide`); see each model card for inputs and strength.

| Key | What it does (input → output) | Size | Gated |
|---|---|---|---|
| `motion-track` | Video with colored spline tracks → video whose objects follow those paths | 0.33 GB | No |
| `edit-anything` | Video + text instruction → video with an object added, removed, replaced or restyled (community, experimental) | 2.6 GB | No |
| `motion-transfer` | Guide video + edited first frame → new subject with the guide's motion (community, experimental; installs ComfyUI-BFSNodes) | 1.3 GB | No |
| `ingredients` | Reference sheet (characters, props, setting) + prompt → video keeping those elements | 1.3 GB | No (Comfy-Org mirror) |
| `clean-plate` | Video → same video with people/vehicles removed, background rebuilt (no mask) | 0.33 GB | Yes |
| `in-outpainting` | Video + mask → masked region replaced/removed, or canvas extended | 1.3 GB | Yes |
| `upscale` | Low-res video → re-rendered at 2× or 4× with new detail (x2 and x4 files) | 1.3 GB | Yes |
| `deblur` | Blurry video → sharp video | 0.9 GB | Yes |
| `decompression` | Video with compression artifacts → cleaned video | 0.9 GB | Yes |
| `colorization` | Black-and-white video → color video | 0.9 GB | Yes |
| `relight` | Exterior video + light-direction ball overlay → relit video (+ bundled workflow) | 0.33 GB | Yes |
| `hdr` | 8-bit SDR video → 16-bit HDR video | 0.33 GB | Yes |
| `day-to-night` | Day video → night version | 0.33 GB | Yes |
| `dubit` | Video + new audio → lip-dubbed video (use the dub-it workflow of ComfyUI-LTXVideo) | 2.5 GB | Yes |
| `foley` | Silent video → same video with sound effects (+ bundled workflow) | 0.23 GB | Yes |
| `water-simulation`, `instant-shave`, `cross-eyed` | Effect IC-LoRAs (water, removes facial hair, cross-eyed) | 0.3–0.9 GB each | Yes |

`all` downloads every key above (~18 GB) and needs `HF_TOKEN`. Union Control (depth/pose/canny/normal guided
video-to-video) is always installed with `ltx23`.

### `h3`

The files of ComfyUI's MiniMax H3 templates (all from Comfy-Org/MiniMax-H3), plus turbo LoRAs to cut the step count.

| Type | File | Folder |
|---|---|---|
| Diffusion model (T2V/I2V) | `minimax_h3_fl2va_pruned_int8_convrot` (21 GB) | `diffusion_models` |
| Text encoder | `qwen3vl_32b_minimax_h3_nvfp4_awq` (15.7 GB) | `text_encoders` |
| VAE | `minimax_h3_video_vae_fp16`, `minimax_h3_audio_vae_fp32` | `vae` |
| Turbo LoRA | `minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16` | `loras` |
| With `DONUT_H3_R2V=1` | `minimax_h3_ref2va_pruned_int8_convrot`, `minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16` | `diffusion_models`, `loras` |

Use the workflows from ComfyUI's Template Library (Video → MiniMax H3); ComfyUI ≥ 0.30.0 is required.

## Custom nodes

ComfyUI-KJNodes and ComfyUI-VideoHelperSuite for every model set; ComfyUI-LTXVideo for `ltx25` and `ltx23`;
ComfyUI-BFSNodes when `DONUT_LORAS` includes `motion-transfer`
(+ comfyui_controlnet_aux and ComfyUI-Video-Depth-Anything when `DONUT_UNION=1`).
Each node is pinned to a commit in the script; update the hash there to move to a newer version.
Their `requirements.txt` are installed with the image's torch/torchvision/torchaudio versions as constraints,
so the image's CUDA build of torch is never replaced.

## Usage

1. For `ltx25` or gated `ltx23` LoRAs: accept the licenses of those Lightricks repos on Hugging Face, and in
   Vast → Settings → Environment Variables add `HF_TOKEN` (a **read-only** token).
   Never put the token in this repo or in the template itself.
2. Template: image `vastai/comfy:v0.42.1-cuda-12.9-py312`, disk ≥ 100 GB (≥ 120 GB for `h3` with `DONUT_H3_R2V=1`), env
   `PROVISIONING_SCRIPT=<raw URL of provision_donut.sh>`, optionally `DONUT_MODEL=ltx23|ltx25|h3` (default `ltx23`)
   and `DONUT_LORAS=...`.
3. Rent an instance. ComfyUI stays on "Loading" until provisioning ends.
   Progress: Instance Portal → Instance Logs (`ok <file>` / `FAIL <file>` lines),
   or `/workspace/donut_provision.log`. Short step-by-step status: `/workspace/donut_status.txt`
   (first line shows the model set and GPU, last line `READY` or `FAILED: …`). `/workspace/.donut_ready` is created
   only when every download, node install and workflow check succeeded.
4. Check the network line early: before the big downloads the script times one ~0.7 GB file and writes
   `network N MB/s`, or `SLOW NETWORK: N MB/s` when below `DONUT_MIN_MBPS` (default 50 MB/s, ~15 min for a
   ~45 GB set). On a slow host, destroy the instance and rent another. While downloading, the log gets a
   `progress … GB in models, N MB/s` line every minute, and the status file ends with the total download time.
   The Docker image pull before the script starts is not measured, so filter hosts by network speed when renting
   (≥ 2 Gbps advertised; a host advertising 812 Mbps delivered ~100 Mbps in a test).

## Choosing the image

The image's CUDA version must be supported by the host driver (`CUDA` / `cuda_max_good` filter in Vast search).
In a snapshot of RTX 4090 offers (2026-10-29), 35 of 43 could run the `cuda-12.9` image but only 20 of 43 the
`cuda-13.2` one, so prefer `cuda-12.9` on RTX 4090. Both tags ship the same ComfyUI version.

## RTX 4090 (24 GB) notes

- Pick hosts with ≥ 64 GB RAM: none of the model sets fits in 24 GB VRAM together with its text encoder, so ComfyUI
  moves the text encoder (and for `ltx23` part of the 29.5 GB checkpoint) to system RAM.
- `ltx25`: transformer 21.5 GB + text encoder 15.4 GB; leaves about 2.5 GB VRAM while sampling.
- `ltx23`: the fp8 checkpoint is larger than 24 GB, so part of it is streamed from RAM each step (slower).
- `h3`: start with 5 s clips at ~768×512 and the 8-step turbo LoRA, then raise resolution/length while
  watching VRAM. Do not install `ComfyUI-MiniMaxH3-Cache`.

## MiniMax H3 license

The MiniMax H3 Community License grants use only outside its Excluded Territories: the European Union,
the United Kingdom, South Korea and the United States. The text does not say whether this refers to where you are,
where the model runs or where users are, so the cautious reading is all three: rent `h3` hosts outside those
territories, or get a separate license from MiniMax. Commercial products above $20M yearly revenue need prior
written permission, and products must show "MiniMax H3" in their UI. Read the full license before use.

## Known issues / notes

- Vast runs a given `PROVISIONING_SCRIPT` URL only once per instance (the URL is hashed); a reboot does not re-run it.
  After changing the script, point the template at a new URL (e.g. the raw URL of the new commit).
- The script only uses `/workspace/ComfyUI` (the copy ComfyUI runs from) and stops with `FAILED` if it does not
  appear within 10 minutes, instead of installing into another ComfyUI copy that the running server never sees.
- The Union Control IC-LoRA is an LTX-2.3 LoRA; its compatibility with the LTX-2.5 model is not verified yet.
- In the "Jupyter" launch mode Jupyter is not proxied by the Instance Portal; use SSH (`-L 8080:localhost:8080`) instead.
- Some RTX 5090 hosts fail to attach the GPU (`unresolvable CDI devices`); destroy and pick another host.
- Do not use a bare `wait` after `exec > >(tee ...)`: bash ≥ 5.1 also waits on the process substitution and hangs.
  The script waits only on the download PIDs.
- Token hygiene: use a read-only HF token and revoke it after testing; env vars are visible on the rented host.
- Custom nodes are fetched with `GIT_LFS_SKIP_SMUDGE=1`: ComfyUI-LTXVideo keeps example images in Git LFS, and a
  failed LFS download aborted its checkout on a test host.
