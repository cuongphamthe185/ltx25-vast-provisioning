# LTX-2.5 ComfyUI provisioning for Vast.ai

Provisioning script for a Vast.ai instance running the `vastai/comfy:v0.42.1-cuda-13.2-py312` image.
It sets up ComfyUI for LTX-2.5 video-to-video with IC-LoRAs (Layout-to-Render, Union Control).

## What it installs (~42 GB)

| Type | File | Source repo |
|---|---|---|
| Diffusion model | `ltx-2.5-22b-distilled-transformer-comfy-int8-convrot` | Lightricks/LTX-2.5 (gated) |
| Text encoder | `gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot` | Lightricks/LTX-2.5 (gated) |
| VAE | `ltx-2.5-video-vae-bf16`, `ltx-2.5-audio-vae-bf16` | Lightricks/LTX-2.5 (gated) |
| Latent upscaler | `ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0` | Lightricks/LTX-2.5 (gated) |
| IC-LoRA | `ltx-2.5-22b-ic-lora-layout-to-render-1.0` | Lightricks/LTX-2.5-22b-IC-LoRA-Layout-To-Render (gated) |
| IC-LoRA | `ltx-2.3-22b-ic-lora-union-control-ref0.5` | Lightricks/LTX-2.3-22b-IC-LoRA-Union-Control |

Custom nodes: ComfyUI-LTXVideo, ComfyUI-KJNodes, ComfyUI-VideoHelperSuite
(+ comfyui_controlnet_aux and ComfyUI-Video-Depth-Anything when `DONUT_UNION=1`).

It also downloads the official `LTX-2.5_ICLoRA_Layout_To_Render_Two_Stage_Distilled.json` workflow and
rewrites the model names to the int8 files above (`LTX-2.5_ICLoRA_Layout_To_Render_int8.json`).

## Usage

1. Accept the licenses of the gated Lightricks repos on Hugging Face.
2. In Vast → Settings → Environment Variables, add `HF_TOKEN` (a **read-only** token).
   Never put the token in this repo or in the template itself.
3. Template: image `vastai/comfy:v0.42.1-cuda-13.2-py312`, disk ≥ 100 GB, env
   `PROVISIONING_SCRIPT=<raw URL of provision_donut.sh>`.
4. Rent an instance. ComfyUI stays on "Loading" until provisioning ends.
   Progress: Instance Portal → Instance Logs (`ok <file>` / `FAIL <file>` lines),
   or `/workspace/donut_provision.log`; done when `/workspace/.donut_ready` exists.

## Known issues / notes

- Vast runs a given `PROVISIONING_SCRIPT` URL only once per instance (the URL is hashed); a reboot does not re-run it.
- In the "Jupyter" launch mode Jupyter is not proxied by the Instance Portal; use SSH (`-L 8080:localhost:8080`) instead.
- Some RTX 5090 hosts fail to attach the GPU (`unresolvable CDI devices`); destroy and pick another host.
- Do not use a bare `wait` after `exec > >(tee ...)`: bash ≥ 5.1 also waits on the process substitution and hangs.
  The script waits only on the download PIDs.
- Token hygiene: use a read-only HF token and revoke it after testing; env vars are visible on the rented host.
