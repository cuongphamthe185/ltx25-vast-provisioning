#!/bin/bash
# Donut provisioning for Vast.ai (image vastai/comfy:v0.42.1-cuda-12.9-py312 or -cuda-13.2-py312)
# Used as PROVISIONING_SCRIPT (raw URL) -> runs after Supervisor starts; output also shows in the
# Instance Portal logs. ComfyUI waits for provisioning to finish before starting.
# DONUT_MODEL picks the model set (default ltx23):
#   ltx23  LTX-2.3 IC-LoRA Union Control (fp8). DONUT_LORAS adds video-to-video LoRAs
#          (comma-separated keys, "all" or "none"; default motion-track, see ltx23_lora below).
#          Gated LoRAs need HF_TOKEN from an account that accepted their license.
#   ltx25  LTX-2.5 v2v with IC-LoRAs (int8). Needs HF_TOKEN (Vast account env var) with access to
#          Lightricks/LTX-2.5 + Layout-To-Render.
#   h3     MiniMax H3 T2V/I2V (pruned int8). No token needed. DONUT_H3_R2V=1 adds reference-to-video.
#          Check the MiniMax H3 license territory rules before renting a host (see README).
# Optional: DONUT_UNION=1 also installs Union Control preprocessors (depth / pose / canny).
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
  ltx25|ltx23|h3) ;;
  *) status "FAILED: unknown DONUT_MODEL=$DONUT_MODEL (use ltx25, ltx23 or h3)"; exit 1 ;;
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

# keep the image's CUDA build of torch: custom node requirements must not up/downgrade it
TORCH_PIN=/workspace/.torch_constraints.txt
pip freeze | grep -iE '^(torch|torchvision|torchaudio)==' > $TORCH_PIN
echo "torch pins: $(tr '\n' ' ' < $TORCH_PIN)"

pip install -q -U -c $TORCH_PIN "huggingface_hub[hf_xet]" >/dev/null
export HF_HUB_ENABLE_HF_TRANSFER=0 HF_XET_HIGH_PERFORMANCE=1

# ---- models (~42-67 GB depending on DONUT_MODEL), downloaded in parallel ----
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

# ltx23 video-to-video LoRAs selectable with DONUT_LORAS. Open: motion-track, edit-anything,
# motion-transfer, ingredients; all others are gated (accept the license on the repo page, set HF_TOKEN).
LTX23_LORAS="motion-track edit-anything motion-transfer clean-plate in-outpainting ingredients upscale deblur
  decompression colorization relight hdr day-to-night dubit foley water-simulation instant-shave cross-eyed"
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
    *) return 1 ;;
  esac
}
LORAS=${DONUT_LORAS:-motion-track}
[ "$LORAS" = all ] && LORAS=$LTX23_LORAS
LORAS=${LORAS//,/ }

FAILS=0

# ---- network check: time one real ~0.7 GB file before the parallel downloads start ----
# Same file for every model set so results compare across hosts; "SLOW NETWORK" in the status file
# means this host will take far too long (the 9 GB image pull before this script is not measured).
MIN_MBPS=${DONUT_MIN_MBPS:-50}   # MB/s; at 50 MB/s a ~45 GB model set takes ~15 min
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
ltx23)  # ~42 GB; files of ComfyUI's LTX-2.3 IC-LoRA Union Control template + spatial upscaler
  get Lightricks/LTX-2.3-fp8 ltx-2.3-22b-distilled-fp8.safetensors $M/checkpoints & PIDS+=($!)
  get Comfy-Org/ltx-2 split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors $M/text_encoders & PIDS+=($!)
  get Comfy-Org/ltx-2 split_files/loras/gemma-3-12b-it-abliterated_lora_rank64_bf16.safetensors $M/loras & PIDS+=($!)
  get Lightricks/LTX-2.3-22b-IC-LoRA-Union-Control ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors $M/loras & PIDS+=($!)
  get Lightricks/LTX-2.3 ltx-2.3-spatial-upscaler-x2-1.1.safetensors $M/latent_upscale_models & PIDS+=($!)
  for k in $LORAS; do
    [ "$k" = none ] && continue
    src=$(ltx23_lora "$k") || { echo "FAIL unknown lora $k (DONUT_LORAS)"; FAILS=$((FAILS+1)); continue; }
    read -r repo files <<< "$src"
    for p in $files; do
      d=$M/loras; [[ $p == *.json ]] && d=$COMFY/user/default/workflows
      get "$repo" "$p" "$d" & PIDS+=($!)
    done
  done
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
esac

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
add_node() { # git_url commit
  local d; d=$(basename "$1" .git)
  if [ ! -d "$d" ]; then
    git init -q "$d" && git -C "$d" fetch -q --depth 1 "$1" "$2" && git -C "$d" checkout -q FETCH_HEAD \
      || { echo "FAIL node $d"; rm -rf "$d"; FAILS=$((FAILS+1)); return; }
  fi
  if [ -f "$d/requirements.txt" ] && ! pip install -q -c $TORCH_PIN -r "$d/requirements.txt" >/dev/null; then
    echo "FAIL pip $d"; FAILS=$((FAILS+1)); return
  fi
  echo "node $d $(git -C "$d" rev-parse --short HEAD)"
}
# MiniMax H3 runs on core ComfyUI nodes; the LTX nodes are only needed for the LTX model sets
[ "$DONUT_MODEL" != h3 ] && add_node https://github.com/Lightricks/ComfyUI-LTXVideo.git 220e1d45aa0469f518e982102fca4dca92a61862
add_node https://github.com/kijai/ComfyUI-KJNodes.git 37a6c45a07bb06cc392431ddbbc741e691c467f4
add_node https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git 4d907bee61e92c2e65af3bd6383a4e4d356126d1
# the EditAnything motion-transfer LoRA runs through the BFS looping sampler
if [ "$DONUT_MODEL" = ltx23 ] && [[ " $LORAS " == *" motion-transfer "* ]]; then
  add_node https://github.com/alisson-anjos/ComfyUI-BFSNodes.git 1e76045b19a99882f1331c9d322a26fac60ae9b8
fi
if [ "${DONUT_UNION:-0}" = "1" ]; then
  add_node https://github.com/Fannovel16/comfyui_controlnet_aux.git a587a4c1594524c1d2de5cd1a86cd868ff448e1c
  add_node https://github.com/yuvraj108c/ComfyUI-Video-Depth-Anything.git a0db08e63d1ea571601c45cde4aaee0acdd0544d
fi
pip freeze | grep -iE '^(torch|torchvision|torchaudio)==' | diff -q - $TORCH_PIN >/dev/null \
  || { echo "FAIL torch changed: $(pip freeze | grep -iE '^torch==')"; FAILS=$((FAILS+1)); }

# ---- ltx25: official Layout-to-Render workflow, patched to the int8 weights we downloaded ----
# ltx23 / h3 use the workflow templates bundled with ComfyUI (Template Library -> Video)
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

# ComfyUI is held until provisioning finishes, so it starts with the new nodes/models; no restart needed
if [ "$FAILS" -eq 0 ]; then
  touch /workspace/.donut_ready
  status "READY"
else
  status "FAILED: $FAILS step(s), see FAIL lines in $LOG"
fi
echo "=== donut provision done $(date -u +%FT%TZ)"
