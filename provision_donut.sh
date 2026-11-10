#!/bin/bash
# Donut provisioning for Vast.ai (image vastai/comfy:v0.42.1-cuda-12.9-py312 or -cuda-13.2-py312)
# Used as PROVISIONING_SCRIPT (raw URL) -> runs after Supervisor starts; output also shows in the
# Instance Portal logs. ComfyUI waits for provisioning to finish before starting.
# DONUT_MODEL picks the model set (default ltx23):
#   ltx23  LTX-2.3 T2V / I2V / FLF2V / IC-LoRA Union Control (fp8). DONUT_LORAS adds LoRAs: video-to-video,
#          reference, camera and style (comma-separated keys, "all" or "none"; default motion-track, see
#          ltx23_lora below). Gated LoRAs need HF_TOKEN from an account that accepted their license;
#          Civitai LoRAs need CIVITAI_TOKEN (a civitai.com API key in the Vast account env).
#   ltx25  LTX-2.5 v2v with IC-LoRAs (int8). Needs HF_TOKEN (Vast account env var) with access to
#          Lightricks/LTX-2.5 + Layout-To-Render.
#   h3     MiniMax H3 T2V/I2V (pruned int8). No token needed. DONUT_H3_R2V=1 adds reference-to-video.
#   h3swap MiniMax H3 Ref2VA with the BFS Character Swap v1.1 and Motion Transfer LoRAs and their workflows:
#          replace the person in a video with the person (face, hair, clothes) in a reference image.
#          Also installs the qwenedit set below (to build the full-body reference picture).
#          No token needed. Check the MiniMax H3 license territory rules before renting a host (see README).
#   qwenedit Qwen-Image-Edit 2511 (int8) only, for ComfyUI's "Qwen Image Edit 2511 Int8" template: up to 3
#          pictures (a person, an outfit...) + a prompt -> a new picture. ~31 GB, no token needed.
#   qwen21 Qwen-Image 2.1 (int8): text-to-image and editing with up to 10 reference pictures, the files of
#          ComfyUI's five Qwen Image 2.1 templates (base and Turbo), ~44 GB + LoRAs. DONUT_LORAS picks
#          Qwen-Image 2.1 LoRAs (see qwen21_lora below; default all, needs CIVITAI_TOKEN).
#          Qwen Research License: non-commercial use only.
# Optional: DONUT_UNION=1 also installs Union Control preprocessors (depth / pose / canny).
# Optional: DONUT_EXTRA_LORAS="hf:<owner>/<repo>/<file>,civitai:<version id>,https://..." downloads more LoRAs
#           into models/loras for any model set. On a running instance: bash /workspace/donut_add.sh <same source>.
# Log: /workspace/donut_provision.log   Status: /workspace/donut_status.txt
# Done marker: /workspace/.donut_ready (only written when every step succeeded)
set -uo pipefail
LOG=/workspace/donut_provision.log
STATUS=/workspace/donut_status.txt
exec > >(tee -a "$LOG") 2>&1
status() { echo "$(date -u +%FT%TZ) $*" | tee -a "$STATUS"; }
rm -f /workspace/.donut_ready
DONUT_MODEL=${DONUT_MODEL:-ltx23}
status "start model=$DONUT_MODEL gpu=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)"
case "$DONUT_MODEL" in
  ltx25|ltx23|h3|h3swap|qwenedit|qwen21) ;;
  *) status "FAILED: unknown DONUT_MODEL=$DONUT_MODEL (use ltx25, ltx23, h3, h3swap, qwenedit or qwen21)"; exit 1 ;;
esac

# the base image syncs ComfyUI into /workspace on first boot and runs it from there; wait for it.
# Never fall back to another copy: models put there would be invisible to the running ComfyUI.
COMFY=/workspace/ComfyUI
for i in $(seq 1 120); do [ -f $COMFY/main.py ] && break; sleep 5; done
[ -f $COMFY/main.py ] || { status "FAILED: $COMFY/main.py not found after 10 min"; exit 1; }
. /venv/main/bin/activate
echo "COMFY=$COMFY"
M=$COMFY/models
mkdir -p $M/diffusion_models $M/checkpoints $M/text_encoders $M/vae $M/latent_upscale_models $M/loras \
  $M/geometry_estimation $COMFY/user/default/workflows
[ "$DONUT_MODEL" = h3swap ] && mkdir -p $M/vae_approx $M/RMBG/BiRefNet
FAILS=0

# the h3swap workflows use core nodes added in ComfyUI 0.39.2
if [ "$DONUT_MODEL" = h3swap ]; then
  CV=$(cd $COMFY && python -c 'from comfyui_version import __version__; print(__version__)' 2>/dev/null)
  if printf '%s\n' 0.39.2 "${CV:-0}" | sort -V -C; then
    echo "ComfyUI $CV"
  else
    echo "FAIL ComfyUI ${CV:-unknown} is older than 0.39.2 (h3swap workflows)"; FAILS=$((FAILS+1))
  fi
fi
# the Qwen Image 2.1 templates use the core nodes TextEncodeQwenImage21 and QwenImage21Cache (in ComfyUI 0.42.1)
if [ "$DONUT_MODEL" = qwen21 ] && ! grep -q QwenImage21Cache $COMFY/comfy_extras/nodes_qwen.py 2>/dev/null; then
  echo "FAIL this ComfyUI has no Qwen-Image 2.1 nodes (use the vastai/comfy:v0.42.1 image or newer)"; FAILS=$((FAILS+1))
fi

# keep the image's CUDA build of torch: custom node requirements must not up/downgrade it
TORCH_PIN=/workspace/.torch_constraints.txt
pip freeze | grep -iE '^(torch|torchvision|torchaudio)==' > $TORCH_PIN
echo "torch pins: $(tr '\n' ' ' < $TORCH_PIN)"

pip install -q -U -c $TORCH_PIN "huggingface_hub[hf_xet]" >/dev/null
export HF_HUB_ENABLE_HF_TRANSFER=0 HF_XET_HIGH_PERFORMANCE=1

# ---- models (~42-74 GB depending on DONUT_MODEL), downloaded in parallel ----
status "downloading models ($DONUT_MODEL)"
get() { # repo path dest_dir
  local f; f=$(basename "$2")
  if [ -s "$3/$f" ]; then echo "skip $f"; return; fi
  if hf download "$1" "$2" --local-dir "/workspace/.hf_tmp/$f" >/dev/null && mv "/workspace/.hf_tmp/$f/$2" "$3/$f"; then
    echo "ok $f"
  else
    echo "FAIL $f"; return 1
  fi
}
civ() { # civitai_model_version_id file_name dest_dir; Civitai downloads need an API key (CIVITAI_TOKEN)
  local tmp=/workspace/.hf_tmp/civitai_$2
  if [ -s "$3/$2" ]; then echo "skip $2"; return; fi
  if [ -z "${CIVITAI_TOKEN:-}" ]; then echo "FAIL $2 (CIVITAI_TOKEN not set)"; return 1; fi
  mkdir -p /workspace/.hf_tmp
  # abort a stalled transfer (< 100 KB/s for 60 s) instead of hanging the whole provisioning run
  if curl -fsSL --retry 3 --connect-timeout 30 --speed-limit 102400 --speed-time 60 \
       -H "Authorization: Bearer $CIVITAI_TOKEN" -o "$tmp" "https://civitai.com/api/download/models/$1" \
   && mv "$tmp" "$3/$2"; then
    echo "ok $2"
  else
    rm -f "$tmp"; echo "FAIL $2"; return 1
  fi
}

# ltx23 LoRAs selectable with DONUT_LORAS. Gated (accept the license on the repo page, set HF_TOKEN):
# the Lightricks IC-LoRAs except motion-track. Civitai keys (civitai:<model version id>) need CIVITAI_TOKEN.
# All others are open on Hugging Face.
LTX23_LORAS="motion-track edit-anything motion-transfer clean-plate in-outpainting ingredients upscale deblur
  decompression colorization relight hdr day-to-night dubit foley water-simulation instant-shave cross-eyed
  msr id-lora 3dreal cameraman transition human-motion crisp-enhance soft-enhance fantasy-realism
  scifi-cyberpunk pixar-toon painterly fantasy-anime pbr-3d hardcut framerush swordplay camera-controls"
ltx23_lora() { # key -> "repo file..." (a .json file is a workflow)
  local L=Lightricks/LTX-2.3-22b
  case "$1" in
    motion-track)    echo "$L-IC-LoRA-Motion-Track-Control ltx-2.3-22b-ic-lora-motion-track-control-ref0.5.safetensors" ;;
    edit-anything)   echo "Alissonerdx/EditAnything edit_anything_v1.1_r256.safetensors" ;;
    motion-transfer) echo "Alissonerdx/EditAnything edit_anything_30k_v0.1_motion_transfer_r128.safetensors" ;;
    clean-plate)     echo "$L-IC-LoRA-Clean-Plate ltx-2.3-22b-ic-lora-clean-plate-1.0.safetensors" ;;
    in-outpainting)  echo "$L-IC-LoRA-In-Outpainting ltx-2.3-22b-ic-lora-in-outpainting-0.9.safetensors" ;;
    ingredients)     echo "Comfy-Org/ltx-2.3 split_files/loras/ltx-2.3-22b-ic-lora-ingredients-0.9.safetensors" ;;
    upscale)         echo "$L-IC-LoRA-Pixel-Spatial-Upscaler ltx-2.3-22b-ic-lora-pixel-spatial-upscaler-x2-0.9.safetensors ltx-2.3-22b-ic-lora-pixel-spatial-upscaler-x4-0.9.safetensors" ;;
    deblur)          echo "$L-IC-LoRA-Deblur ltx-2.3-22b-ic-lora-deblur-0.9.safetensors" ;;
    decompression)   echo "$L-IC-LoRA-Decompression ltx-2.3-22b-ic-lora-decompression-0.9.safetensors" ;;
    colorization)    echo "$L-IC-LoRA-Colorization ltx-2.3-22b-ic-lora-colorization-0.9.safetensors" ;;
    relight)         echo "$L-IC-LoRA-Relight ltx-2.3-22b-ic-lora-relight-1.0.safetensors LTX-2.3_Relight_ICLoRA_SingleStage_Distilled.json" ;;
    hdr)             echo "$L-IC-LoRA-HDR ltx-2.3-22b-ic-lora-hdr-0.9.safetensors" ;;
    day-to-night)    echo "$L-IC-LoRA-Day-To-Night ltx-2.3-22b-ic-lora-day-to-night-0.9.safetensors" ;;
    dubit)           echo "$L-IC-LoRA-DubIt ltx-2.3-22b-ic-lora-dubit-0.9.safetensors" ;;
    foley)           echo "$L-LoRA-Foley-V2A ltx-2.3-22b-lora-foley-v2a-1.0.safetensors ltx-2.3-foley-v2a.json" ;;
    water-simulation) echo "$L-IC-LoRA-Water-Simulation ltx-2.3-22b-ic-lora-water-simulation-0.9.safetensors" ;;
    instant-shave)   echo "$L-IC-LoRA-Instant-Shave ltx-2.3-22b-ic-lora-instant-shave-0.9.safetensors" ;;
    cross-eyed)      echo "$L-IC-LoRA-Cross-Eyed ltx-2.3-22b-ic-lora-cross-eyed-0.9.safetensors" ;;
    # reference, camera and motion helpers
    msr)             echo "LiconStudio/LTX-2.3-Multiple-Subject-Reference LTX-2.3-Licon-MSR-V2.safetensors" ;;
    id-lora)         echo "Comfy-Org/ltx-2.3 split_files/loras/ltx-2.3-id-lora-talkvid-3k.safetensors" ;;
    3dreal)          echo "fal/LTX-2.3-3DREAL-LoRA 3DREAL-strong-v2.safetensors" ;;
    cameraman)       echo "Cseti/LTX2.3-22B_IC-LoRA-Cameraman_v2 LTX2.3-22B_IC-LoRA-Cameraman_v2_14000.safetensors" ;;
    transition)      echo "joyfox/LTX-2.3-Transition-LORA ltx2.3-transition.safetensors" ;;
    human-motion)    echo "vpakarinen/better-human-motion-ltx-lora motion_stabilizer_ltx_lora_v2.safetensors" ;;
    # looks (plain LoRAs added on top of the T2V / I2V / FLF2V templates)
    crisp-enhance)   echo "vrgamedevgirl84/LTX_2.3_Crisp_Enhance_Style_LoRa LTX2.3_Crisp_Enhance.safetensors" ;;
    soft-enhance)    echo "vrgamedevgirl84/LTX_2.3_Soft_Enhance_Style_LoRa LTX2.3_Soft_Enhance.safetensors" ;;
    fantasy-realism) echo "vrgamedevgirl84/LTX_2.3_Fantasy_Realism_Style_LoRa Fantasy_Realism.safetensors" ;;
    scifi-cyberpunk) echo "vrgamedevgirl84/LTX_2.3_Cinematic_Sci-fi-Cyberpunk_Style_LoRa Cinematic_sci-fi-cyberpunk.safetensors" ;;
    pixar-toon)      echo "vrgamedevgirl84/LTX_2.3_Pixar_Toon_Style_LoRa Pixar_Toon.safetensors" ;;
    painterly)       echo "vrgamedevgirl84/LTX_2.3_Fantasy_Painterly_Style_LoRa Fantasy_Painterly.safetensors" ;;
    fantasy-anime)   echo "vrgamedevgirl84/LTX_2.3_Fantasy_Anime_Style_LoRa Fantasy_Anime.safetensors" ;;
    # Civitai: "civitai:<model version id> <file name to save as>"
    pbr-3d)          echo "civitai:2964961 LTX2.3_pbrstyle_V1.1.safetensors" ;;
    hardcut)         echo "civitai:2819456 ltx23_cinematic_hardcut.safetensors" ;;
    framerush)       echo "civitai:3269911 FrameRush-V2_c2-st1000.safetensors" ;;
    swordplay)       echo "civitai:2815367 LTX-2.3-swordplay.safetensors" ;;
    camera-controls) echo "civitai:2944022 LTX2.3_CameraControls.safetensors" ;;
    *) return 1 ;;
  esac
}
# qwen21 LoRAs selectable with DONUT_LORAS (default all). Qwen-Image 2.1 only: Qwen-Image-Edit 2509/2511 LoRAs
# do not load on it (other architecture) and the reverse. Civitai keys need CIVITAI_TOKEN.
QWEN21_LORAS="qma anyangle vertical-angle next-scene cinematic filmstills lenovo nicegirls asian-mix detail-fix
  bfs-head outfit-swap consistency breasts-slider"
qwen21_lora() { # key -> "repo file"
  case "$1" in
    # camera angle and next shot (edit an existing picture)
    qma)            echo "gribbliest/qwen-image-2.1-qma-camera-angles qwen-image-2.1-qma-camera-angles.safetensors" ;;
    anyangle)       echo "lilylilith/QI_2.1_AnyAngle QI2.1_AnyAngle.safetensors" ;;
    vertical-angle) echo "civitai:3439657 qwen2.1-consistent_vertical_angle_change_v2.safetensors" ;;
    next-scene)     echo "akhaliq/Qwen-Image-2.1-Next-Scene-LoRA next_scene_step2500.safetensors" ;;
    # light and photo look
    cinematic)      echo "civitai:3387119 cinematic_qwen21_2_c1-st5000.safetensors" ;;
    filmstills)     echo "Danrisi/filmstills_qwen2.1 filmstills_qwen21.safetensors" ;;
    # realistic people
    lenovo)         echo "Danrisi/lenovo_qwen2.1 lenovo_qwen21.safetensors" ;;
    nicegirls)      echo "Danrisi/nicegirls2_qwen2.1 nicegirls_v2_qwen21.safetensors" ;;
    asian-mix)      echo "civitai:3374888 hina_QwenImage2.1_asianMix_Lora_v3.0-rank64.safetensors" ;;
    detail-fix)     echo "e-n-v-y/Qwen-Image-2.1-Fix-v2.0 qwen2.1-detail-fix-2.0.safetensors" ;;
    # editing tools: head swap (+ its workflow, see below), outfit swap, keep the unedited parts unchanged
    bfs-head)       echo "Alissonerdx/BFS-Best-Face-Swap bfs_head_v1.1_qwen_2.1.safetensors" ;;
    outfit-swap)    echo "civitai:3381922 qwen-image-2.1-outfit-swap.safetensors" ;;
    consistency)    echo "civitai:3364470 qwen-image-2.1-consistency.safetensors" ;;
    # body slider (adult-content creator, LoRA strength -20..+20)
    breasts-slider) echo "civitai:3346363 Pornmaster_QI2.1_Breasts_Slider_V1.safetensors" ;;
    *) return 1 ;;
  esac
}
case "$DONUT_MODEL" in
  qwen21) LSET=$QWEN21_LORAS; LORAS=${DONUT_LORAS:-all} ;;
  *)      LSET=$LTX23_LORAS;  LORAS=${DONUT_LORAS:-motion-track} ;;
esac
[ "$LORAS" = all ] && LORAS=$LSET
LORAS=${LORAS//,/ }
LORAS=$(echo $LORAS)   # one space between keys, so the " key " checks below also match list ends and line breaks

# ---- donut_add.sh: download one more model file by link, during provisioning (DONUT_EXTRA_LORAS) or later ----
ADD=/workspace/donut_add.sh
cat > $ADD <<'ADDSH'
#!/bin/bash
# Download one model file into /workspace/ComfyUI/models/<folder> (default loras), then press R in ComfyUI.
#   bash /workspace/donut_add.sh hf:<owner>/<repo>/<path in repo> [folder]   (gated repos need HF_TOKEN)
#   bash /workspace/donut_add.sh civitai:<model version id> [folder]         (needs CIVITAI_TOKEN)
#   bash /workspace/donut_add.sh https://<direct link> [folder]              (saved under the name the server sends)
set -uo pipefail
src=${1:?usage: donut_add.sh <hf:owner/repo/file | civitai:version id | https://...> [folder]}
dir=/workspace/ComfyUI/models/${2:-loras}
mkdir -p "$dir" /workspace/.hf_tmp
tmp=$(mktemp -d /workspace/.hf_tmp/add.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
fetch() { # url [token]; Authorization is not forwarded when the link redirects to another host
  local h=(); [ -n "${2:-}" ] && h=(-H "Authorization: Bearer $2")
  (cd "$tmp" && curl -fsSL --retry 3 --connect-timeout 30 --speed-limit 102400 --speed-time 60 "${h[@]}" -OJ "$1")
}
case "$src" in
  hf:*/*/*) p=${src#hf:}; repo=$(echo "$p" | cut -d/ -f1-2); file=${p#*/*/}
            [ -s "$dir/$(basename "$file")" ] && { echo "skip $(basename "$file")"; exit 0; }
            hf download "$repo" "$file" --local-dir "$tmp/hf" >/dev/null && mv "$tmp/hf/$file" "$tmp/" ;;
  civitai:*) [ -n "${CIVITAI_TOKEN:-}" ] || { echo "FAIL $src (CIVITAI_TOKEN not set)"; exit 1; }
             fetch "https://civitai.com/api/download/models/${src#civitai:}" "$CIVITAI_TOKEN" ;;
  https://huggingface.co/*) fetch "$src" "${HF_TOKEN:-}" ;;
  https://civitai.com/*)    fetch "$src" "${CIVITAI_TOKEN:-}" ;;
  https://*)                fetch "$src" ;;
  *) echo "FAIL $src (use hf:<owner>/<repo>/<file>, civitai:<version id> or https://...)"; exit 1 ;;
esac
f=$(find "$tmp" -maxdepth 1 -type f ! -name '.*' | head -1)
[ -n "$f" ] && [ -s "$f" ] || { echo "FAIL $src"; exit 1; }
n=$(basename "$f")
if [ -s "$dir/$n" ]; then echo "skip $n"; else mv "$f" "$dir/$n" && echo "ok $n -> $dir"; fi
ADDSH
chmod +x $ADD
EXTRA=${DONUT_EXTRA_LORAS:-}
EXTRA=$(echo ${EXTRA//,/ })

# ---- network check: time one real ~0.7 GB file before the parallel downloads start ----
# Same file for every model set so results compare across hosts; "SLOW NETWORK" in the status file
# means this host will take far too long (the 9 GB image pull before this script is not measured).
MIN_MBPS=${DONUT_MIN_MBPS:-50}   # MB/s; at 50 MB/s the ~74 GB ltx23 set takes ~25 min
SPEED_FILE=moge_2_vitl_normal_fp16.safetensors
if [ -s "$M/geometry_estimation/$SPEED_FILE" ]; then
  status "network check skipped ($SPEED_FILE already present)"
else
  T0=$(date +%s.%N)
  if get Comfy-Org/MoGe geometry_estimation/$SPEED_FILE $M/geometry_estimation; then
    MBPS=$(awk -v b="$(stat -c %s "$M/geometry_estimation/$SPEED_FILE")" -v t0="$T0" -v t1="$(date +%s.%N)" \
      'BEGIN { printf "%d", b / 1e6 / (t1 - t0) }')
    if [ "$MBPS" -lt "$MIN_MBPS" ]; then
      status "SLOW NETWORK: $MBPS MB/s (want >= $MIN_MBPS MB/s)"
    else
      status "network $MBPS MB/s"
    fi
  else
    status "network check download failed"; FAILS=$((FAILS+1))
  fi
fi

DL0=$(date +%s)
PIDS=()
# Qwen-Image-Edit 2511 int8 (~31 GB): the files of ComfyUI's "Qwen Image Edit 2511 Int8" template, plus the
# 8-step Lightning LoRA as a middle ground between its 4-step LoRA and the full 20-40 steps
qwen_edit_get() {
  get Comfy-Org/Qwen-Image-Edit_ComfyUI split_files/diffusion_models/qwen_image_edit_2511_int8_convrot.safetensors $M/diffusion_models & PIDS+=($!)
  get Comfy-Org/HunyuanVideo_1.5_repackaged split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors $M/text_encoders & PIDS+=($!)
  get Comfy-Org/Qwen-Image_ComfyUI split_files/vae/qwen_image_vae.safetensors $M/vae & PIDS+=($!)
  for s in 4 8; do
    get lightx2v/Qwen-Image-Edit-2511-Lightning Qwen-Image-Edit-2511-Lightning-${s}steps-V1.0-bf16.safetensors $M/loras & PIDS+=($!)
  done
}
get_loras() { # lookup function (ltx23_lora or qwen21_lora): download the DONUT_LORAS keys in $LORAS
  local k src repo files p d
  for k in $LORAS; do
    [ "$k" = none ] && continue
    src=$($1 "$k") || { echo "FAIL unknown lora $k (DONUT_LORAS)"; FAILS=$((FAILS+1)); continue; }
    read -r repo files <<< "$src"
    for p in $files; do
      d=$M/loras; [[ $p == *.json ]] && d=$COMFY/user/default/workflows
      if [[ $repo == civitai:* ]]; then civ "${repo#civitai:}" "$p" "$d" & PIDS+=($!)
      else get "$repo" "$p" "$d" & PIDS+=($!); fi
    done
  done
}
case "$DONUT_MODEL" in
ltx25)  # ~42 GB, gated
  R=Lightricks/LTX-2.5
  get $R diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors $M/diffusion_models & PIDS+=($!)
  get $R text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors $M/text_encoders & PIDS+=($!)
  get $R vae/ltx-2.5-video-vae-bf16.safetensors $M/vae & PIDS+=($!)
  get $R vae/ltx-2.5-audio-vae-bf16.safetensors $M/vae & PIDS+=($!)
  get $R latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors $M/latent_upscale_models & PIDS+=($!)
  get Lightricks/LTX-2.5-22b-IC-LoRA-Layout-To-Render ltx-2.5-22b-ic-lora-layout-to-render-1.0.safetensors $M/loras & PIDS+=($!)
  get Lightricks/LTX-2.3-22b-IC-LoRA-Union-Control ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors $M/loras & PIDS+=($!)
  ;;
ltx23)  # ~74 GB; files of ComfyUI's LTX-2.3 templates: T2V/I2V (dev + distilled LoRA), FLF2V and IC-LoRA (distilled)
  get Lightricks/LTX-2.3-fp8 ltx-2.3-22b-distilled-fp8.safetensors $M/checkpoints & PIDS+=($!)
  get Lightricks/LTX-2.3-fp8 ltx-2.3-22b-dev-fp8.safetensors $M/checkpoints & PIDS+=($!)
  get Comfy-Org/ltx-2.3 split_files/loras/ltx_2.3_22b_distilled_1.1_lora_dynamic_fro09_avg_rank_111_bf16.safetensors $M/loras & PIDS+=($!)
  get Comfy-Org/ltx-2 split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors $M/text_encoders & PIDS+=($!)
  get Comfy-Org/ltx-2 split_files/loras/gemma-3-12b-it-abliterated_lora_rank64_bf16.safetensors $M/loras & PIDS+=($!)
  get Lightricks/LTX-2.3-22b-IC-LoRA-Union-Control ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors $M/loras & PIDS+=($!)
  get Lightricks/LTX-2.3 ltx-2.3-spatial-upscaler-x2-1.1.safetensors $M/latent_upscale_models & PIDS+=($!)
  get_loras ltx23_lora
  ;;
h3)  # ~44 GB (+23 GB with DONUT_H3_R2V=1); files of ComfyUI's MiniMax H3 templates + turbo LoRAs
  H=Comfy-Org/MiniMax-H3
  get $H diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors $M/diffusion_models & PIDS+=($!)
  get $H text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors $M/text_encoders & PIDS+=($!)
  get $H vae/minimax_h3_video_vae_fp16.safetensors $M/vae & PIDS+=($!)
  get $H vae/minimax_h3_audio_vae_fp32.safetensors $M/vae & PIDS+=($!)
  get $H loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors $M/loras & PIDS+=($!)
  if [ "${DONUT_H3_R2V:-0}" = "1" ]; then
    get $H diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors $M/diffusion_models & PIDS+=($!)
    get $H loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors $M/loras & PIDS+=($!)
  fi
  ;;
h3swap)  # ~86 GB (incl. qwenedit); the models of the BFS Character Swap v1.1 and Motion Transfer v1.0 workflows (Alissonerdx)
  H=Comfy-Org/MiniMax-H3; A=Alissonerdx/Minimax-H3-ComfyUI
  get $H diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors $M/diffusion_models & PIDS+=($!)
  get $H text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors $M/text_encoders & PIDS+=($!)
  get $H vae/minimax_h3_video_vae_fp16.safetensors $M/vae & PIDS+=($!)
  get $H vae/minimax_h3_audio_vae_fp32.safetensors $M/vae & PIDS+=($!)
  # vision-language model that looks at the reference image and writes the swap prompt
  get Comfy-Org/MOSS-Image text_encoders/qwen3.5_9b_w4a8_gptq.safetensors $M/text_encoders & PIDS+=($!)
  get drbaph/MiniMax-H3-Turbo-Lora-ComfyUI experimental/minimax_h3_dmd_ref2va_8step_turbo_pruned.safetensors $M/loras & PIDS+=($!)
  # swap / motion / head LoRAs, and the LMS LoRA + latent upscaler of the optional second pass (1280x704)
  for f in minimax_h3_character_swap_v1.1_ref2va_fro minimax_h3_motion_transfer_v1.0_ref2va \
           minimax_h3_head_swap_v1.0_r32 minimax_h3_lms_v1.0_r64; do
    get $A loras/$f.safetensors $M/loras & PIDS+=($!)
  done
  get $A latent_upscaler/h3_upscaler_lms_v0.1.safetensors $M/latent_upscale_models & PIDS+=($!)
  get Kijai/MiniMax-H3-TAE vae_approx/taeh3.safetensors $M/vae_approx & PIDS+=($!)
  # background removal of the reference image (ComfyUI-RMBG would fetch it on the first run otherwise)
  for f in BiRefNet-general.safetensors birefnet.py BiRefNet_config.py config.json; do
    get 1038lab/BiRefNet $f $M/RMBG/BiRefNet & PIDS+=($!)
  done
  qwen_edit_get
  ;;
qwenedit)
  qwen_edit_get
  ;;
qwen21)  # ~44 GB; files of ComfyUI's Qwen Image 2.1 templates: Text to Image, Image Edit, their Turbo copies, Remove Background
  Q=Comfy-Org/Qwen-Image-2.1
  # the two Qwen3.5 9B files are the templates' prompt enhancers (T2I / I2I); their loaders are in the graphs either way
  for f in diffusion_models/qwen_image_2.1_int8_convrot diffusion_models/qwen_image_2.1_turbo_int8_convrot \
           text_encoders/qwen3vl_8b_int8_convrot vae/qwen_image_2.1_vae_bf16 \
           text_encoders/qwen3.5_9b_qwen_image_2.1_pe_t2i.int8_convrot text_encoders/qwen3.5_9b_qwen_image_2.1_pe_i2i.int8_convrot; do
    get $Q $f.safetensors $M/${f%%/*} & PIDS+=($!)
  done
  # the 8-step speed LoRA of the BFS head swap workflow
  if [[ " $LORAS " == *" bfs-head "* ]]; then
    get $Q loras/p_q_image_2.1_8_steps_v0.1_comfyui_bf16.safetensors $M/loras & PIDS+=($!)
  fi
  get_loras qwen21_lora
  ;;
esac
for s in $EXTRA; do bash $ADD "$s" & PIDS+=($!); done

# a progress line every 60 s while the models download, so a slow host shows up early in the log
on_disk() { du -sB1 /workspace/.hf_tmp $M 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'; }  # allocated bytes, not apparent size
( prev=$(on_disk)
  while sleep 60; do
    cur=$(on_disk)
    awk -v c="$cur" -v p="$prev" 'BEGIN { printf "progress %.1f GB in models, %d MB/s\n", c / 1e9, (c - p) / 1e6 / 60 }'
    prev=$cur
  done ) &
MON=$!

# ---- custom nodes (while models download), pinned to known commits ----
# skip Git LFS files (example images/videos): their download can fail and abort the checkout
export GIT_LFS_SKIP_SMUDGE=1
cd $COMFY/custom_nodes
add_node() { # git_url commit [pip packages to install instead of the node's requirements.txt]
  local d req; d=$(basename "$1" .git)
  if [ ! -d "$d" ]; then
    git init -q "$d" && git -C "$d" fetch -q --depth 1 "$1" "$2" && git -C "$d" checkout -q FETCH_HEAD \
      || { echo "FAIL node $d"; rm -rf "$d"; FAILS=$((FAILS+1)); return; }
  fi
  if [ $# -ge 3 ]; then read -ra req <<< "$3"
  elif [ -f "$d/requirements.txt" ]; then req=(-r "$d/requirements.txt")
  else req=(); fi
  if [ ${#req[@]} -gt 0 ] && ! pip install -q -c $TORCH_PIN "${req[@]}" >/dev/null; then
    echo "FAIL pip $d"; FAILS=$((FAILS+1)); return
  fi
  echo "node $d $(git -C "$d" rev-parse --short HEAD)"
}
# MiniMax H3 runs on core ComfyUI nodes; the LTX nodes are only needed for the LTX model sets
[[ $DONUT_MODEL == ltx* ]] && add_node https://github.com/Lightricks/ComfyUI-LTXVideo.git 220e1d45aa0469f518e982102fca4dca92a61862
add_node https://github.com/kijai/ComfyUI-KJNodes.git 37a6c45a07bb06cc392431ddbbc741e691c467f4
add_node https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git 4d907bee61e92c2e65af3bd6383a4e4d356126d1
# the EditAnything motion-transfer LoRA runs through the BFS looping sampler; the h3swap Shot Planner
# workflows (long videos split into shots, rendered and joined) need BFSNodes >= 1.113.0 (this pin: 1.115.33)
if [ "$DONUT_MODEL" = h3swap ] || { [ "$DONUT_MODEL" = ltx23 ] && [[ " $LORAS " == *" motion-transfer "* ]]; }; then
  add_node https://github.com/alisson-anjos/ComfyUI-BFSNodes.git 1e76045b19a99882f1331c9d322a26fac60ae9b8
fi
if [ "$DONUT_MODEL" = h3swap ]; then
  # only the BiRefNet node is used; its full requirements (GroundingDINO, SAM, onnxruntime...) are skipped,
  # and the pack loads each of its node files on its own, so the unused ones just fail to import
  add_node https://github.com/1038lab/ComfyUI-RMBG.git a66a5e641a54988d80ed6aad18946081c85f309e "timm einops kornia"
  # the commit the BFS workflows were saved with: later commits added a widget, which shifts the saved values
  # ("device: 'fp16' not in list") and drops the workflows' video outputs at validation
  add_node https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler.git 6a4b191e8af583b7c097f564690325f91d18c2e2
fi
# the Multiple-Subject-Reference LoRA reads a reference video built by the Licon MSR node
# (up to 4 subject images + a background image)
if [ "$DONUT_MODEL" = ltx23 ] && [[ " $LORAS " == *" msr "* ]]; then
  add_node https://github.com/liconstudio/ComfyUI-Licon-MSR.git 94a52bfec735ff6f802c480f7fe8fdac1d279a7f
fi
# the BFS head swap workflow (qwen21 bfs-head) shows its result in rgthree's Image Comparer node
if [ "$DONUT_MODEL" = qwen21 ] && [[ " $LORAS " == *" bfs-head "* ]]; then
  add_node https://github.com/rgthree/rgthree-comfy.git bc48c6aaeca87bedbc14245d89f9bc6be37a630e
fi
if [ "${DONUT_UNION:-0}" = "1" ]; then
  add_node https://github.com/Fannovel16/comfyui_controlnet_aux.git a587a4c1594524c1d2de5cd1a86cd868ff448e1c
  add_node https://github.com/yuvraj108c/ComfyUI-Video-Depth-Anything.git a0db08e63d1ea571601c45cde4aaee0acdd0544d
fi
pip freeze | grep -iE '^(torch|torchvision|torchaudio)==' | diff -q - $TORCH_PIN >/dev/null \
  || { echo "FAIL torch changed: $(pip freeze | grep -iE '^torch==')"; FAILS=$((FAILS+1)); }

# ---- ltx23: copies of ComfyUI's bundled T2V / I2V / FLF2V templates with Duration set to 10 s ----
# Built on the instance from the installed template package, so nothing upstream is stored in this repo.
if [ "$DONUT_MODEL" = ltx23 ]; then
  if ! python - "$COMFY/user/default/workflows" 10 <<'PY'
import json, os, sys, importlib.util
out_dir, secs = sys.argv[1], int(sys.argv[2])
spec = importlib.util.find_spec("comfyui_workflow_templates_json")
src = os.path.join(os.path.dirname(spec.origin), "templates")
NON_WIDGET = {"IMAGE", "MASK", "IMAGE,MASK", "LATENT", "AUDIO", "VIDEO", "MODEL", "CLIP", "VAE"}
for name, title in [("video_ltx2_3_t2v", "T2V"), ("video_ltx2_3_i2v", "I2V"), ("video_ltx2_3_flf2v", "FLF2V")]:
    w = json.load(open(os.path.join(src, name + ".json"), encoding="utf-8"))
    subs = {s["id"]: s for s in w.get("definitions", {}).get("subgraphs", [])}
    inner = 0
    for n in w["nodes"]:
        sg = subs.get(n["type"])
        if not sg:
            continue
        # the Duration primitive inside the subgraph (used directly by proxy-widget templates)
        for x in sg["nodes"]:
            if x["type"] == "PrimitiveInt" and x.get("title") == "Duration" and x["widgets_values"][0] == 5:
                x["widgets_values"][0] = secs
                inner += 1
        # the value shown on the subgraph node itself, when the template stores it there
        vals = n.get("widgets_values") or []
        ins = [i for i in sg["inputs"] if i.get("type") not in NON_WIDGET]
        for k, i in enumerate(ins):
            if i.get("label") == "duration" and k < len(vals) and vals[k] == 5:
                vals[k] = secs
    if inner != 1:
        sys.exit(f"{name}: expected one Duration primitive set to 5, found {inner}")
    out = f"LTX-2.3_{title}_{secs}s.json"
    with open(os.path.join(out_dir, out), "w", encoding="utf-8") as f:
        json.dump(w, f)
    print("workflow", out)
PY
  then
    echo "FAIL 10 s workflows"; FAILS=$((FAILS+1))
  fi
fi

# ---- ltx25: official Layout-to-Render workflow, patched to the int8 weights we downloaded ----
# ltx23 / h3 use the workflow templates bundled with ComfyUI (Template Library -> Video), plus the 10 s copies above
WF=
if [ "$DONUT_MODEL" = ltx25 ]; then
  WF=$COMFY/user/default/workflows/LTX-2.5_ICLoRA_Layout_To_Render_int8.json
  if hf download Lightricks/LTX-2.5-22b-IC-LoRA-Layout-To-Render LTX-2.5_ICLoRA_Layout_To_Render_Two_Stage_Distilled.json --local-dir /workspace/.hf_tmp/wf >/dev/null \
   && sed -e 's/ltx-2.5-22b-distilled-transformer-bf16/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot/g' \
          -e 's/gemma4-12b-with-proj-ltx-2.5-bf16/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot/g' \
          /workspace/.hf_tmp/wf/LTX-2.5_ICLoRA_Layout_To_Render_Two_Stage_Distilled.json > "$WF"; then
    echo "workflow ok"
  else
    echo "FAIL workflow"; FAILS=$((FAILS+1))
  fi
fi

# ---- h3swap: the BFS Character Swap v1.1 and Motion Transfer v1.0 workflows (native and Shot Planner) ----
# Pinned to the repo revision they were checked against; their model loaders keep the author's folders
# ("Downloads/", "minimax/"), so the file names are reset to the files downloaded above.
WFPY=/workspace/.donut_wf.py
cat > $WFPY <<'PY'
import json, os, sys
# the Motion Transfer planner loads the int8 H3 text encoder (25 GB); the nvfp4 one (15.7 GB) is downloaded instead.
# The BFS Qwen-Image 2.1 head swap workflow names PrunaAI's 8-step LoRA by the author's local file name, and
# samples with deis_2m from the RES4LYF node pack: use the Comfy-Org file and the core deis sampler.
RENAME = {"qwen3vl_32b_minimax_h3_int8_convrot.safetensors": "qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors",
          "p_qwen_image_2.1_8step_v0.1.safetensors": "p_q_image_2.1_8_steps_v0.1_comfyui_bf16.safetensors"}
SAMPLER = {"deis_2m": "deis"}
def nodes(w):
    yield from w.get("nodes", [])
    for sg in w.get("definitions", {}).get("subgraphs", []):
        yield from sg.get("nodes", [])
def model_widgets(n, keys=("widgets_values",)):  # (container, key) of every widget holding a model file name
    out = []
    for k in keys:
        v = n.get(k)
        items = enumerate(v) if isinstance(v, list) else v.items() if isinstance(v, dict) else []
        out += [(v, i) for i, x in items if isinstance(x, str) and x.endswith(".safetensors")]
    return out
mode, args = sys.argv[1], sys.argv[2:]
if mode == "patch":  # src_dir out_dir name...
    for name in args[2:]:
        w = json.load(open(os.path.join(args[0], name), encoding="utf-8"))
        for n in nodes(w):
            for v, i in model_widgets(n, ("widgets_values", "widgets_values_named")):
                b = v[i].replace("\\", "/").rsplit("/", 1)[-1]
                v[i] = RENAME.get(b, b)
            wv = n.get("widgets_values")
            if n.get("type") in ("KSampler", "KSamplerAdvanced") and isinstance(wv, list):
                n["widgets_values"] = [SAMPLER.get(x, x) if isinstance(x, str) else x for x in wv]
        json.dump(w, open(os.path.join(args[1], name), "w", encoding="utf-8"))
        print("workflow", name)
else:  # check models_dir workflow...: every model an enabled node loads must be on disk
    have = {f for _, _, fs in os.walk(args[0]) for f in fs}
    bad = 0
    for path in args[1:]:
        for n in nodes(json.load(open(path, encoding="utf-8"))):
            if n.get("mode", 0) != 0:  # 2 = muted, 4 = bypassed
                continue
            for v, i in model_widgets(n):
                if v[i] not in have:
                    print(f"FAIL {os.path.basename(path)} needs missing model {v[i]}"); bad += 1
    sys.exit(1 if bad else 0)
PY
CHECKWF=()
if [ "$DONUT_MODEL" = h3swap ]; then
  for w in minimax_h3_character_swap_workflow_native_nodes_v1.1 minimax_h3_character_swap_workflow_v1.1 \
           minimax_h3_motion_transfer_workflow_native_nodes_v1.0 minimax_h3_motion_transfer_workflow_planner_v1.0; do
    if hf download Alissonerdx/Minimax-H3-ComfyUI workflows/$w.json --revision 64244a4fdf226c8d37b8470d1893b6ba9ab54de1 \
         --local-dir /workspace/.hf_tmp/h3wf >/dev/null \
     && python $WFPY patch /workspace/.hf_tmp/h3wf/workflows $COMFY/user/default/workflows $w.json; then
      CHECKWF+=("$COMFY/user/default/workflows/$w.json")
    else
      echo "FAIL workflow $w"; FAILS=$((FAILS+1))
    fi
  done
fi
# ---- qwen21 bfs-head: the BFS Head Swap workflow for Qwen-Image 2.1 (same pinned-revision + patch approach) ----
if [ "$DONUT_MODEL" = qwen21 ] && [[ " $LORAS " == *" bfs-head "* ]]; then
  w="Head Swap V1 Qwen 2.1 Workflow.json"
  if hf download Alissonerdx/BFS-Best-Face-Swap "workflows/$w" --revision 2209ae537ac5e883d6ec7db5b7bd6dccf1a0eba7 \
       --local-dir /workspace/.hf_tmp/bfswf >/dev/null \
   && python $WFPY patch /workspace/.hf_tmp/bfswf/workflows $COMFY/user/default/workflows "$w"; then
    CHECKWF+=("$COMFY/user/default/workflows/$w")
  else
    echo "FAIL workflow $w"; FAILS=$((FAILS+1))
  fi
fi

# ---- apps (ComfyUI App Mode forms, Apps sidebar): kept in this repo's apps/ folder and fetched from the same
# commit as this script, so a template pinned to a commit also pins its apps ----
APPS=()
if [ "$DONUT_MODEL" = h3swap ] || [ "$DONUT_MODEL" = qwenedit ]; then
  for a in Donut_Anh.app.json; do
    if [ -n "${PROVISIONING_SCRIPT:-}" ] \
     && curl -fsSL --retry 3 --connect-timeout 30 -o "$COMFY/user/default/workflows/$a" "${PROVISIONING_SCRIPT%/*}/apps/$a"; then
      echo "app $a"; APPS+=("$COMFY/user/default/workflows/$a")
    else
      echo "FAIL app $a (PROVISIONING_SCRIPT must be the raw URL of this script)"; FAILS=$((FAILS+1))
    fi
  done
fi

status "waiting for model downloads"
for p in "${PIDS[@]}"; do   # only the downloads; a bare wait would also wait on the tee log process and hang
  wait "$p" || FAILS=$((FAILS+1))
done
kill $MON 2>/dev/null
status "downloads finished in $(( ($(date +%s) - DL0) / 60 )) min"
rm -rf /workspace/.hf_tmp
ls -la $M/diffusion_models $M/checkpoints $M/text_encoders $M/vae $M/latent_upscale_models $M/loras $M/geometry_estimation
df -h /workspace | tail -1

# every model file the workflow references must exist, or ComfyUI fails only when the user hits Run
if [ -s "$WF" ]; then
  for f in $(grep -oE '[A-Za-z0-9._-]+\.safetensors' "$WF" | sort -u); do
    [ -n "$(find $M -name "$f" -print -quit)" ] || { echo "FAIL workflow needs missing model $f"; FAILS=$((FAILS+1)); }
  done
fi
if [ ${#CHECKWF[@]} -gt 0 ]; then
  python $WFPY check $M "${CHECKWF[@]}" || FAILS=$((FAILS+1))
fi
# the bundled Qwen templates of the model set (and its apps) must find every model they load
TPL=
case "$DONUT_MODEL" in
  h3swap|qwenedit) TPL=image_qwen_image_edit_2511_int8 ;;
  qwen21) TPL="image_qwen_image_2_1_t2i image_qwen_image_2_1_image_edit image_qwen_image_2_1_turbo_t2i
    image_qwen_image_2_1_turbo_image_edit image_qwen_image_2_1_background_removal" ;;
esac
if [ -n "$TPL" ]; then
  TD=$(python -c 'import importlib.util, os; s = importlib.util.find_spec("comfyui_workflow_templates_json"); print(os.path.join(os.path.dirname(s.origin), "templates"))' 2>/dev/null)
  QT=()
  for t in $TPL; do
    if [ -s "$TD/$t.json" ]; then QT+=("$TD/$t.json"); else echo "FAIL template $t.json not found"; FAILS=$((FAILS+1)); fi
  done
  python $WFPY check $M "${QT[@]}" "${APPS[@]}" || FAILS=$((FAILS+1))
fi

# ComfyUI is held until provisioning finishes, so it starts with the new nodes/models; no restart needed
if [ "$FAILS" -eq 0 ]; then
  touch /workspace/.donut_ready
  status "READY"
else
  status "FAILED: $FAILS step(s), see FAIL lines in $LOG"
fi
echo "=== donut provision done $(date -u +%FT%TZ)"
