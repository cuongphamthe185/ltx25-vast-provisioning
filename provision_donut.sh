#!/bin/bash
# Donut / LTX-2.5 provisioning for Vast.ai (image vastai/comfy:v0.42.1-cuda-13.2-py312)
# Used as PROVISIONING_SCRIPT (raw URL) -> runs after Supervisor starts; output also shows in the
# Instance Portal logs. ComfyUI waits for provisioning to finish before starting.
# Needs HF_TOKEN (Vast account env var) with access to Lightricks/LTX-2.5 + Layout-To-Render.
# Optional: DONUT_UNION=1 also installs Union Control preprocessors (depth / pose / canny).
# Log: /workspace/donut_provision.log   Status: /workspace/donut_status.txt
# Done marker: /workspace/.donut_ready (only written when every step succeeded)
set -uo pipefail
LOG=/workspace/donut_provision.log
STATUS=/workspace/donut_status.txt
exec > >(tee -a "$LOG") 2>&1
status() { echo "$(date -u +%FT%TZ) $*" | tee -a "$STATUS"; }
rm -f /workspace/.donut_ready
status "start"

# the base image syncs ComfyUI into /workspace on first boot and runs it from there; wait for it.
# Never fall back to another copy: models put there would be invisible to the running ComfyUI.
COMFY=/workspace/ComfyUI
for i in $(seq 1 120); do [ -f $COMFY/main.py ] && break; sleep 5; done
[ -f $COMFY/main.py ] || { status "FAILED: $COMFY/main.py not found after 10 min"; exit 1; }
. /venv/main/bin/activate
echo "COMFY=$COMFY"
M=$COMFY/models
mkdir -p $M/diffusion_models $M/text_encoders $M/vae $M/latent_upscale_models $M/loras $COMFY/user/default/workflows

# keep the image's CUDA build of torch: custom node requirements must not up/downgrade it
TORCH_PIN=/workspace/.torch_constraints.txt
pip freeze | grep -iE '^(torch|torchvision|torchaudio)==' > $TORCH_PIN
echo "torch pins: $(tr '\n' ' ' < $TORCH_PIN)"

pip install -q -U -c $TORCH_PIN "huggingface_hub[hf_xet]" >/dev/null
export HF_HUB_ENABLE_HF_TRANSFER=0 HF_XET_HIGH_PERFORMANCE=1

# ---- models (~42 GB), downloaded in parallel ----
status "downloading models"
get() { # repo path dest_dir
  local f; f=$(basename "$2")
  if [ -s "$3/$f" ]; then echo "skip $f"; return; fi
  if hf download "$1" "$2" --local-dir "/workspace/.hf_tmp/$f" >/dev/null && mv "/workspace/.hf_tmp/$f/$2" "$3/$f"; then
    echo "ok $f"
  else
    echo "FAIL $f"; return 1
  fi
}
PIDS=()
R=Lightricks/LTX-2.5
get $R diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors $M/diffusion_models & PIDS+=($!)
get $R text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors $M/text_encoders & PIDS+=($!)
get $R vae/ltx-2.5-video-vae-bf16.safetensors $M/vae & PIDS+=($!)
get $R vae/ltx-2.5-audio-vae-bf16.safetensors $M/vae & PIDS+=($!)
get $R latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors $M/latent_upscale_models & PIDS+=($!)
get Lightricks/LTX-2.5-22b-IC-LoRA-Layout-To-Render ltx-2.5-22b-ic-lora-layout-to-render-1.0.safetensors $M/loras & PIDS+=($!)
get Lightricks/LTX-2.3-22b-IC-LoRA-Union-Control ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors $M/loras & PIDS+=($!)

# ---- custom nodes (while models download), pinned to known commits ----
FAILS=0
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
add_node https://github.com/Lightricks/ComfyUI-LTXVideo.git 220e1d45aa0469f518e982102fca4dca92a61862
add_node https://github.com/kijai/ComfyUI-KJNodes.git 37a6c45a07bb06cc392431ddbbc741e691c467f4
add_node https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git 4d907bee61e92c2e65af3bd6383a4e4d356126d1
if [ "${DONUT_UNION:-0}" = "1" ]; then
  add_node https://github.com/Fannovel16/comfyui_controlnet_aux.git a587a4c1594524c1d2de5cd1a86cd868ff448e1c
  add_node https://github.com/yuvraj108c/ComfyUI-Video-Depth-Anything.git a0db08e63d1ea571601c45cde4aaee0acdd0544d
fi
pip freeze | grep -iE '^(torch|torchvision|torchaudio)==' | diff -q - $TORCH_PIN >/dev/null \
  || { echo "FAIL torch changed: $(pip freeze | grep -iE '^torch==')"; FAILS=$((FAILS+1)); }

# ---- official Layout-to-Render workflow, patched to the int8 weights we downloaded ----
WF=$COMFY/user/default/workflows/LTX-2.5_ICLoRA_Layout_To_Render_int8.json
if hf download Lightricks/LTX-2.5-22b-IC-LoRA-Layout-To-Render LTX-2.5_ICLoRA_Layout_To_Render_Two_Stage_Distilled.json --local-dir /workspace/.hf_tmp/wf >/dev/null \
 && sed -e 's/ltx-2.5-22b-distilled-transformer-bf16/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot/g' \
        -e 's/gemma4-12b-with-proj-ltx-2.5-bf16/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot/g' \
        /workspace/.hf_tmp/wf/LTX-2.5_ICLoRA_Layout_To_Render_Two_Stage_Distilled.json > "$WF"; then
  echo "workflow ok"
else
  echo "FAIL workflow"; FAILS=$((FAILS+1))
fi

status "waiting for model downloads"
for p in "${PIDS[@]}"; do   # only the downloads; a bare wait would also wait on the tee log process and hang
  wait "$p" || FAILS=$((FAILS+1))
done
rm -rf /workspace/.hf_tmp
ls -la $M/diffusion_models $M/text_encoders $M/vae $M/latent_upscale_models $M/loras
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
