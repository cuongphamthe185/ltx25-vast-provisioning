# LTX / MiniMax H3 ComfyUI provisioning for Vast.ai

Provisioning script for a Vast.ai instance running the `vastai/comfy:v0.42.1` image
(`-cuda-12.9-py312` or `-cuda-13.2-py312`, see [Choosing the image](#choosing-the-image)).
`DONUT_MODEL` picks which model set it installs into ComfyUI.

## Model sets (`DONUT_MODEL`)

| Value | Model | Size | HF token |
|---|---|---|---|
| `ltx23` (default) | LTX-2.3 text/image-to-video, first-last-frame and IC-LoRA Union Control, fp8, plus the video-to-video LoRAs picked with `DONUT_LORAS` | ~74 GB + LoRAs | Only for gated LoRAs |
| `ltx25` | LTX-2.5 video-to-video with IC-LoRAs (Layout-to-Render, Union Control), int8 | ~42 GB | Required (gated) |
| `h3` | MiniMax H3 text/image-to-video with audio, pruned int8 | ~44 GB (+23 GB with `DONUT_H3_R2V=1`) | Not needed |
| `h3swap` | MiniMax H3 reference-to-video with the Character Swap and Motion Transfer LoRAs: replace the person in a video with the person in a reference image | ~55 GB | Not needed |

Any model set can also download extra LoRAs, see [Adding LoRAs](#adding-loras).

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

The files of ComfyUI's LTX-2.3 Text to Video, Image to Video, First-Last-Frame and IC-LoRA Union Control templates.

| Type | File | Folder | Source repo |
|---|---|---|---|
| Checkpoint (FLF2V, IC-LoRA) | `ltx-2.3-22b-distilled-fp8` (29.5 GB) | `checkpoints` | Lightricks/LTX-2.3-fp8 |
| Checkpoint (T2V, I2V) | `ltx-2.3-22b-dev-fp8` (29.2 GB) | `checkpoints` | Lightricks/LTX-2.3-fp8 |
| LoRA (T2V, I2V) | `ltx_2.3_22b_distilled_1.1_lora_dynamic_fro09_avg_rank_111_bf16` (2.7 GB) | `loras` | Comfy-Org/ltx-2.3 |
| Text encoder | `gemma_3_12B_it_fp4_mixed` (9.45 GB) | `text_encoders` | Comfy-Org/ltx-2 |
| LoRA | `gemma-3-12b-it-abliterated_lora_rank64_bf16` | `loras` | Comfy-Org/ltx-2 |
| IC-LoRA | `ltx-2.3-22b-ic-lora-union-control-ref0.5` | `loras` | Lightricks/LTX-2.3-22b-IC-LoRA-Union-Control |
| Geometry | `moge_2_vitl_normal_fp16` | `geometry_estimation` | Comfy-Org/MoGe |
| Latent upscaler | `ltx-2.3-spatial-upscaler-x2-1.1` | `latent_upscale_models` | Lightricks/LTX-2.3 |

Use the workflows from ComfyUI's Template Library (Video → LTX-2.3). Their sample inputs (images, videos) are
not installed: load your own file into each Load Image / Load Video node before running.
The script also saves 10-second copies of the T2V, I2V and FLF2V templates to the workflow list
(`LTX-2.3_T2V_10s`, `LTX-2.3_I2V_10s`, `LTX-2.3_FLF2V_10s`); they are the bundled graphs with Duration set to 10
(the model renders 249 frames at 25 fps). Any template's length can also be changed in its Duration field.
The ID-LoRA, Ingredients and Style Transition templates need extra LoRAs: add the `id-lora`, `ingredients` and
`transition` keys below.

#### LoRAs (`DONUT_LORAS`)

Comma-separated keys, `all` or `none`; default `motion-track`. Only used with `DONUT_MODEL=ltx23`.
Files go to `models/loras`; bundled workflows go to the workflow list.
- Gated keys need `HF_TOKEN` from an account that accepted the license on each repo page.
- Civitai keys need `CIVITAI_TOKEN` (civitai.com → Account settings → API keys), set in the Vast account env like
  `HF_TOKEN`. Never put it in this repo or in the template.

Without the needed token those keys show up as `FAIL` lines and the run ends `FAILED`.

How to use them:
- IC-LoRAs (video-to-video, reference, camera): load them in the IC-LoRA template (Video → LTX 2.3 IC-LoRA Union
  Control) in place of the Union Control LoRA and give them the guide video or references their model card asks
  for, or use the IC-LoRA workflows of ComfyUI-LTXVideo (`LTXICLoRALoaderModelOnly` + `LTXAddVideoICLoRAGuide`).
- Look and motion LoRAs: add a `LoraLoaderModelOnly` after the checkpoint in the T2V / I2V / FLF2V templates
  (start around 0.7, range 0.4–1.0) and put the trigger word in the prompt when the card names one. They stack;
  keep the total strength modest.
- The community workflows on the model pages are not installed: most need extra node packs and other model files.

Video-to-video (Lightricks and community):

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

Reference, camera and motion ("Output use" = whether generated videos may be used commercially, from the model
license or the Civitai permissions; the LTX-2 Community License of the base model applies on top):

| Key | What it does | Size | Source | Output use |
|---|---|---|---|---|
| `msr` | Up to 4 subject images (characters, vehicles, props) + 1 background image → video keeping all of them. Installs ComfyUI-Licon-MSR, whose `Licon MSR` node turns the images into the reference video | 0.65 GB | LiconStudio (HF) | Yes (Apache-2.0) |
| `id-lora` | Face image + voice sample + prompt → talking video that keeps the identity and the voice (ComfyUI ID-LoRA template) | 1.2 GB | Comfy-Org mirror (HF) | Check (ID-LoRA license "other") |
| `3dreal` | Simple 3D render, for example a Blender animatic → photoreal cinematic video with the same layout and motion. Trigger `3DREAL` | 0.33 GB | fal (HF) | Unclear (license "other") |
| `cameraman` | Reference video (any clip or a Blender camera move) + prompt or start image → new video with the same camera motion | 0.65 GB | Cseti (HF) | Yes (Civitai permissions) |
| `transition` | Stylized transitions between a first and a last frame (ComfyUI Style Transition template); also steadies T2V / I2V motion | 0.39 GB | joyfox, ex valiantcat (HF) | Yes (Apache-2.0) |
| `human-motion` | Smoother, more natural body movement for walking, dancing, fighting (strength 0.4–0.8) | 0.67 GB | vpakarinen (HF) | Yes (Apache-2.0) |
| `hardcut` | Clean cinematic hard cuts between shots inside one generated clip (strength 0.2–1.0) | 0.66 GB | Civitai | Yes |
| `camera-controls` | Makes "the camera pans left / tilts up / zooms in on …" prompts reliable | 0.33 GB | Civitai | No (non-commercial) |
| `swordplay` | Sword fighting moves (slashes, spins, lunges). Trigger `swordplay` | 0.39 GB | Civitai | No |

Looks (plain LoRAs for the T2V / I2V / FLF2V templates):

| Key | Look | Size | Source | Output use |
|---|---|---|---|---|
| `crisp-enhance` | Sharper detail and contrast, polished cinematic finish (the most downloaded LTX-2.3 LoRA on Civitai) | 0.71 GB | vrgamedevgirl84 (HF) | Yes |
| `soft-enhance` | Natural detail with softer contrast; mix with `crisp-enhance` to taste | 0.35 GB | vrgamedevgirl84 (HF) | Yes |
| `fantasy-realism` | Live-action fantasy film: real skin and fabrics, practical sets, grounded light | 0.35 GB | vrgamedevgirl84 (HF) | Yes |
| `scifi-cyberpunk` | Cinematic neo-noir sci-fi: neon cities, high-tech interfaces | 0.35 GB | vrgamedevgirl84 (HF) | Yes |
| `framerush` | Modern action-movie look: explosions, chases, combat, motorbikes | 0.30 GB | Civitai | Yes |
| `pixar-toon` | Stylized 3D animated feature: smooth surfaces, expressive characters, soft materials | 0.35 GB | vrgamedevgirl84 (HF) | Yes |
| `pbr-3d` | Stylized PBR 3D animation like big-studio animated films. Trigger `PBRSty1e` | 0.33 GB | Civitai | No |
| `painterly` | Painted look: visible brush strokes, layered paint textures, luminous light | 0.35 GB | vrgamedevgirl84 (HF) | Yes |
| `fantasy-anime` | Hand-drawn, cel-shaded illustration (2D animation) | 0.35 GB | vrgamedevgirl84 (HF) | Yes |

Starting points per style (copy into `DONUT_LORAS`; the Civitai keys need `CIVITAI_TOKEN`):

| Style | `DONUT_LORAS` |
|---|---|
| Base for reference-driven projects (character / vehicle / location images, Blender layout) | `ingredients,msr,cameraman,human-motion,transition` |
| Cinematic live action | base + `crisp-enhance,soft-enhance,fantasy-realism,3dreal` (+ `framerush,hardcut`) |
| 3D animated film | base + `pixar-toon` (+ `pbr-3d`) |
| Painterly stylized 3D | base + `painterly` (+ `pbr-3d`) |
| 2D animated superhero, cel-shaded | base + `fantasy-anime` |
| Sci-fi | add `scifi-cyberpunk`; sword fights: add `swordplay` |

No open LoRA reproduces a specific studio's show (Arcane, Marvel or DC animated series); the LoRAs trained on those
shows are character LoRAs of protected IP and are left out. Set such a look with reference or keyframe images drawn
in that style (I2V, `msr`, `ingredients`) and the closest look LoRA at a low strength.

`all` downloads every key above (~27 GB) and needs both `HF_TOKEN` and `CIVITAI_TOKEN`. Union Control
(depth/pose/canny/normal guided video-to-video) is always installed with `ltx23`.

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

### `h3swap`

Video-to-video person replacement with the BFS LoRAs of
[Alissonerdx/Minimax-H3-ComfyUI](https://huggingface.co/Alissonerdx/Minimax-H3-ComfyUI): a guide video (the
performance: motion, pose, hands, gaze, lips, background, light, camera) + a reference picture (the person: face,
hair, body, clothes) → the same video with that person. The H3 T2V/I2V model of `h3` is not installed.

| Type | File | Folder | Source repo | Output use |
|---|---|---|---|---|
| Diffusion model | `minimax_h3_ref2va_pruned_int8_convrot` (21.0 GB) | `diffusion_models` | Comfy-Org/MiniMax-H3 | H3 license |
| Text encoder | `qwen3vl_32b_minimax_h3_nvfp4_awq` (15.7 GB) | `text_encoders` | Comfy-Org/MiniMax-H3 | H3 license |
| VAE | `minimax_h3_video_vae_fp16`, `minimax_h3_audio_vae_fp32` (5.5 GB) | `vae` | Comfy-Org/MiniMax-H3 | H3 license |
| Prompt writer (VLM) | `qwen3.5_9b_w4a8_gptq` (7.3 GB): looks at the reference picture and writes the swap prompt | `text_encoders` | Comfy-Org/MOSS-Image | Yes (Apache-2.0) |
| Turbo LoRA | `minimax_h3_dmd_ref2va_8step_turbo_pruned` (2.3 GB), 8 steps | `loras` | drbaph/MiniMax-H3-Turbo-Lora-ComfyUI | Yes (Apache-2.0) |
| LoRA | `minimax_h3_character_swap_v1.1_ref2va_fro` (0.08 GB): replaces the main person of the guide video, strength 1.0, prompt prefix `body_swap:` | `loras` | Alissonerdx | Yes (BFS Character Swap License: no hosted API/SaaS, credit above US $1M yearly revenue) |
| LoRA | `minimax_h3_motion_transfer_v1.0_ref2va` (0.18 GB): 1–4 pictures with roles set in the prompt (several people, clothes, objects, setting) take the guide's motion | `loras` | Alissonerdx | Yes (BFS Motion Transfer License, same terms) |
| LoRA | `minimax_h3_head_swap_v1.0_r32` (0.31 GB): head only, the author's "research model"; can be added to the Character Swap graph to try better lip sync | `loras` | Alissonerdx | Unclear (no license stated) |
| Second pass | `minimax_h3_lms_v1.0_r64` LoRA (1.2 GB) + `h3_upscaler_lms_v0.1` latent upscaler (0.7 GB), up to 1280×704 | `loras`, `latent_upscale_models` | Alissonerdx | Unclear (no license stated) |
| Preview decoder | `taeh3` (0.02 GB) | `vae_approx` | Kijai/MiniMax-H3-TAE | Yes (Apache-2.0) |
| Background removal | `BiRefNet-general` (0.9 GB, + its code and config) for the reference picture | `RMBG/BiRefNet` | 1038lab/BiRefNet | Yes (BiRefNet: MIT) |

Workflows (workflow list, from the repo revision checked with this script; the model names are set to the files above):

| Workflow | Use |
|---|---|
| `minimax_h3_character_swap_workflow_native_nodes_v1.1` | One clip (up to ~15 s, `17n + 5` frames at 24 fps). Load the guide video and one reference picture; the VLM writes the prompt |
| `minimax_h3_character_swap_workflow_v1.1` | BFS Shot Planner: splits a long video into shots, renders each and joins them |
| `minimax_h3_motion_transfer_workflow_native_nodes_v1.0` / `..._planner_v1.0` | Motion Transfer with 1–4 pictures (pictures 2–4 start disabled: select their nodes, Ctrl+B) |

Tips from the LoRA author: one reference picture per run, a clear full-body picture works best for clothes; if the
guide video has several people, name the one to replace; start with a short test clip. Results drift with small
faces, occlusion, fast motion and long clips. Both workflows end with an optional second pass (LMS LoRA + latent
upscaler). Use guide videos and reference pictures only with the consent of the people in them.

Custom nodes added for `h3swap`: ComfyUI-BFSNodes, ComfyUI-RMBG (only BiRefNet's dependencies are installed, so
its other nodes fail to import; the log shows those errors) and Comfyui_Minimax_h3_latent_Upscaler. The run
ends `FAILED` if the image's ComfyUI is older than 0.39.2, which these workflows need.

## Adding LoRAs

Extra LoRAs, for any model set, without changing the script:
- When renting: set `DONUT_EXTRA_LORAS` in the template env (comma-separated). They download with the other files,
  and a failed one makes the run end `FAILED`.
- On a running instance (Jupyter terminal or SSH): `bash /workspace/donut_add.sh <source> [folder]`, then press
  `R` in ComfyUI (or reload the page) so the new file shows in the LoRA lists. `folder` is a folder under
  `models/` (default `loras`).

| Source | Example |
|---|---|
| `hf:<owner>/<repo>/<path in repo>` | `hf:Alissonerdx/Minimax-H3-ComfyUI/loras/minimax_h3_live_wallpaper_v1.0_ref2va_r32.safetensors` |
| `civitai:<model version id>` (needs `CIVITAI_TOKEN`) | `civitai:2944022` (the version id is in the model page URL, `?modelVersionId=`) |
| A direct `https://` link | `https://huggingface.co/<repo>/resolve/main/<file>` (sends `HF_TOKEN` or `CIVITAI_TOKEN` to those two sites) |

A file that is already there is skipped. A LoRA must match the model set: LTX-2.3 LoRAs do not load on H3 and the
reverse.

## Custom nodes

ComfyUI-KJNodes and ComfyUI-VideoHelperSuite for every model set; ComfyUI-LTXVideo for `ltx25` and `ltx23`;
ComfyUI-BFSNodes when `DONUT_LORAS` includes `motion-transfer` and for `h3swap`; ComfyUI-RMBG and
Comfyui_Minimax_h3_latent_Upscaler for `h3swap`; ComfyUI-Licon-MSR when `DONUT_LORAS` includes `msr`
(+ comfyui_controlnet_aux and ComfyUI-Video-Depth-Anything when `DONUT_UNION=1`).
Each node is pinned to a commit in the script; update the hash there to move to a newer version.
Their `requirements.txt` are installed with the image's torch/torchvision/torchaudio versions as constraints,
so the image's CUDA build of torch is never replaced.

## Usage

1. For `ltx25` or gated `ltx23` LoRAs: accept the licenses of those Lightricks repos on Hugging Face, and in
   Vast → Settings → Environment Variables add `HF_TOKEN` (a **read-only** token). For Civitai LoRAs add
   `CIVITAI_TOKEN` there too. Never put a token in this repo or in the template itself.
2. Template: image `vastai/comfy:v0.42.1-cuda-12.9-py312`, disk ≥ 100 GB (≥ 120 GB for `ltx23` with `DONUT_LORAS=all` or `h3` with `DONUT_H3_R2V=1`), env
   `PROVISIONING_SCRIPT=<raw URL of provision_donut.sh>`, optionally `DONUT_MODEL=ltx23|ltx25|h3|h3swap` (default
   `ltx23`), `DONUT_LORAS=...` and `DONUT_EXTRA_LORAS=...`. Keep one template per model set (for example
   "Donut LTX-2.3" and "Donut H3 Swap"), each with its own `DONUT_MODEL`: picking the template picks the models,
   since editing env on Vast saves a new template.
3. Rent an instance. ComfyUI stays on "Loading" until provisioning ends.
   Progress: Instance Portal → Instance Logs (`ok <file>` / `FAIL <file>` lines),
   or `/workspace/donut_provision.log`. Short step-by-step status: `/workspace/donut_status.txt`
   (first line shows the model set and GPU, last line `READY` or `FAILED: …`). `/workspace/.donut_ready` is created
   only when every download, node install and workflow check succeeded.
4. Check the network line early: before the big downloads the script times one ~0.7 GB file and writes
   `network N MB/s`, or `SLOW NETWORK: N MB/s` when below `DONUT_MIN_MBPS` (default 50 MB/s, ~25 min for the
   ~74 GB `ltx23` set). The file is small, so the number reads low on fast hosts (101 MB/s measured on a host that
   then downloaded at ~700 MB/s); trust the `progress` lines for the real speed. On a slow host, destroy the instance and rent another. While downloading, the log gets a
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
- `ltx23`: both fp8 checkpoints are larger than 24 GB, so part of the model is streamed from RAM each step (slower).
  Measured on a 4090 at 1280×704 (2026-11-02): 5 s clips took ~100 s for T2V (first run, includes model load),
  ~36 s for I2V, ~65 s for IC-LoRA Union Control; the 10 s copies took ~127 s for T2V (first run), ~71 s for I2V
  and ~126 s for FLF2V. A 10 s run uses ~40 GB of host RAM, so prefer hosts with ≥ 96 GB RAM for 10 s clips.
- `h3`: start with 5 s clips at ~768×512 and the 8-step turbo LoRA, then raise resolution/length while
  watching VRAM. Do not install `ComfyUI-MiniMaxH3-Cache`.
- `h3swap`: the H3 model (21 GB), its text encoder (15.7 GB) and the prompt-writing VLM (7.3 GB) take turns in
  VRAM, so pick hosts with ≥ 96 GB RAM. Not measured on a 4090 yet; start with a 4–5 s clip at ~0.4–0.6 MP.

## MiniMax H3 license

The MiniMax H3 Community License grants use only outside its Excluded Territories: the European Union,
the United Kingdom, South Korea and the United States. The text does not say whether this refers to where you are,
where the model runs or where users are, so the cautious reading is all three: rent `h3` hosts outside those
territories, or get a separate license from MiniMax. Commercial products above $20M yearly revenue need prior
written permission, and products must show "MiniMax H3" in their UI. Read the full license before use.
This applies to `h3swap` too; its LoRAs add their own terms (see the `h3swap` table).

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
