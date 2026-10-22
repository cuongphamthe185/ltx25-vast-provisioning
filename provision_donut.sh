#!/bin/bash
# Donut / LTX-2.5 provisioning for Vast.ai (image vastai/comfy:v0.42.1-cuda-13.2-py312)
# Used as PROVISIONING_SCRIPT (raw URL) -> runs after Supervisor starts; output also shows in the
# Instance Portal logs. ComfyUI waits for provisioning to finish before starting.
# Needs HF_TOKEN (Vast account env var) with access to Lightricks/LTX-2.5 + Layout-To-Render.
# Optional: DONUT_UNION=1 also installs Union Control preprocessors (depth / pose / canny).
# Log: /workspace/donut_provision.log   Done marker: /workspace/.donut_ready
set -uo pipefail
LOG=/workspace/donut_provision.log
exec > >(tee -a "$LOG") 2>&1
echo "=== donut provision start $(date -u +%FT%TZ)"

# the base image syncs ComfyUI into /workspace on first boot; wait for it
for i in $(seq 1 120); do [ -f /workspace/ComfyUI/main.py ] && break; sleep 5; done
. /venv/main/bin/activate
COMFY=$(ls -d /workspace/ComfyUI /opt/workspace-internal/ComfyUI 2>/dev/null | head -1)
[ -z "$COMFY" ] && { echo "ComfyUI dir not found"; exit 1; }
echo "COMFY=$COMFY"
M=$COMFY/models
mkdir -p $M/diffusion_models $M/text_encoders $M/vae $M/latent_upscale_models $M/loras $COMFY/user/default/workflows

pip install -q -U "huggingface_hub[hf_xet]" >/dev/null
export HF_HUB_ENABLE_HF_TRANSFER=0 HF_XET_HIGH_PERFORMANCE=1

# ---- models (~42 GB), downloaded in parallel ----
get() { # repo path dest_dir
  local f; f=$(basename "$2")
  if [ -s "$3/$f" ]; then echo "skip $f"; return; fi
  hf download "$1" "$2" --local-dir "/workspace/.hf_tmp/$f" >/dev/null && mv "/workspace/.hf_tmp/$f/$2" "$3/$f" && echo "ok $f" || echo "FAIL $f"
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

# ---- custom nodes (while models download) ----
cd $COMFY/custom_nodes
node() { # git_url [pip extra]
  local d; d=$(basename "$1" .git)
  [ -d "$d" ] || git clone -q --depth 1 "$1"
  [ -f "$d/requirements.txt" ] && pip install -q -r "$d/requirements.txt" >/dev/null
  echo "node $d"
}
node https://github.com/Lightricks/ComfyUI-LTXVideo.git
node https://github.com/kijai/ComfyUI-KJNodes.git
node https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git
if [ "${DONUT_UNION:-0}" = "1" ]; then
  node https://github.com/Fannovel16/comfyui_controlnet_aux.git
  node https://github.com/yuvraj108c/ComfyUI-Video-Depth-Anything.git
fi

# ---- official Layout-to-Render workflow, patched to the int8 weights we downloaded ----
WF=$COMFY/user/default/workflows/LTX-2.5_ICLoRA_Layout_To_Render_int8.json
hf download Lightricks/LTX-2.5-22b-IC-LoRA-Layout-To-Render LTX-2.5_ICLoRA_Layout_To_Render_Two_Stage_Distilled.json --local-dir /workspace/.hf_tmp/wf >/dev/null \
 && sed -e 's/ltx-2.5-22b-distilled-transformer-bf16/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot/g' \
        -e 's/gemma4-12b-with-proj-ltx-2.5-bf16/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot/g' \
        /workspace/.hf_tmp/wf/LTX-2.5_ICLoRA_Layout_To_Render_Two_Stage_Distilled.json > "$WF" && echo "workflow ok"

wait "${PIDS[@]}"   # only the downloads; a bare wait would also wait on the tee log process and hang
rm -rf /workspace/.hf_tmp
ls -la $M/diffusion_models $M/text_encoders $M/vae $M/latent_upscale_models $M/loras
df -h /workspace | tail -1

# ComfyUI is held until provisioning finishes, so it starts with the new nodes/models; no restart needed
touch /workspace/.donut_ready
echo "=== donut provision done $(date -u +%FT%TZ)"
