#!/bin/bash

source /venv/main/bin/activate
COMFYUI_DIR=${WORKSPACE}/ComfyUI

# Packages are installed after nodes so we can fix them...

APT_PACKAGES=(
    #"package-1"
    #"package-2"
)

PIP_PACKAGES=(
    "onnx"
    "onnxruntime-gpu"
)

NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/cubiq/ComfyUI_essentials"
    "https://github.com/crystian/ComfyUI-Crystools.git"
	"https://github.com/kijai/ComfyUI-KJNodes.git"
	"https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
	"https://github.com/Lightricks/ComfyUI-LTXVideo.git"
)

WORKFLOWS=(
	"https://s3.cloudstore.pixerati.cloud/public-scripts/workflows/video_ltx2_i2v.json"
)

CHECKPOINT_MODELS=(
    "https://huggingface.co/Lightricks/LTX-2/resolve/main/ltx-2-19b-dev-fp8.safetensors"
    )

DIFFUSION_MODELS=(
)

UNET_MODELS=(
)

CLIP_MODELS=(
    "https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors"
)

LORA_MODELS=(
    "https://huggingface.co/Lightricks/LTX-2/resolve/main/ltx-2-19b-distilled-lora-384.safetensors"
)

VAE_MODELS=(
)

UPSCALE_MODELS=(
)

LATENT_UPSCALE_MODELS=(
	"https://huggingface.co/Lightricks/LTX-2/resolve/main/ltx-2-spatial-upscaler-x2-1.0.safetensors"
)

ESRGAN_MODELS=(
)

CONTROLNET_MODELS=(
)

### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ###

# --- Add this helper to detect the ComfyUI local port (inside the container) ---
function provisioning_detect_comfy_local_port() {
    # 1) Explicit env override
    if [[ -n "${COMFY_LOCAL_PORT:-}" ]]; then
        echo "${COMFY_LOCAL_PORT}"
        return 0
    fi

    # 2) Parse COMFYUI_ARGS (e.g., "--disable-auto-launch --port 18188 --enable-cors-header")
    if [[ -n "${COMFYUI_ARGS:-}" ]]; then
        local p
        p="$(awk '{
            for(i=1;i<=NF;i++){
                if($i=="--port"){print $(i+1); exit}
                if($i ~ /^--port=/){sub(/^--port=/,"",$i); print $i; exit}
            }
        }' <<< "${COMFYUI_ARGS}")"
        if [[ -n "$p" ]]; then
            echo "$p"
            return 0
        fi
    fi

    # 3) Parse /etc/portal.yaml if available (looks for comfyui entry's local_port)
    if [[ -r /etc/portal.yaml ]]; then
        # naive grep; good enough for the stock file structure
        local y
        y="$(awk '
            BEGIN{found=0}
            /name: *ComfyUI/{found=1}
            found && /local_port:/{gsub(/[^0-9]/,""); if($0!=""){print $0; exit}}
        ' /etc/portal.yaml)"
        if [[ -n "$y" ]]; then
            echo "$y"
            return 0
        fi
    fi

    # 4) Default
    echo 18188
}


# Install rclone (if not present), write a minimal config from env vars, and start a background sync daemon.
function provisioning_setup_output_sync() {

    # Require basic env vars
    if [[ -z "${S3_ENDPOINT}" || -z "${S3_ACCESS_KEY}" || -z "${S3_SECRET_KEY}" || -z "${S3_BUCKET}" ]]; then
        printf "[output-sync] Missing S3 env vars; skipping daemon.\n"
        return 0
    fi

    # Ensure curl + rclone exist
    if ! command -v rclone >/dev/null 2>&1; then
        if ! command -v curl >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y --no-install-recommends ca-certificates curl
        fi
        curl -fsSL https://rclone.org/install.sh | bash
    fi

    # rclone config (uses named remote 'mystore')
    mkdir -p /root/.config/rclone
    cat >/root/.config/rclone/rclone.conf <<EOF
[mystore]
type = s3
provider = Minio
env_auth = false
access_key_id = ${S3_ACCESS_KEY}
secret_access_key = ${S3_SECRET_KEY}
endpoint = https://${S3_ENDPOINT}
acl = private
force_path_style = true
no_check_bucket = true
EOF
    chmod 600 /root/.config/rclone/rclone.conf


    local daemon=/usr/local/bin/comfy-output-sync.sh
    cat >"$daemon"<<'EOSH'
#!/usr/bin/env bash
set -euo pipefail

# ---- Inputs from env / defaults ----
LOCAL_DIR="/workspace/ComfyUI/output"
REMOTE_NAME="mystore"
S3_BUCKET="${S3_BUCKET:-comfy-prod}"
S3_PREFIX="${S3_PREFIX:-output/}"   # base prefix (no session here)
# Compute a per-session prefix once at daemon start (MMDDYYYYHHMM). Allow override.
SESSION_PREFIX="${OUTPUT_SESSION_PREFIX:-$(date +%m%d%Y%H%M)}"

# Normalize slashes and build remote like: mystore:bucket/output/<session>/
CLEAN_PREFIX="${S3_PREFIX%/}"       # strip trailing slash
REMOTE="${REMOTE_NAME}:${S3_BUCKET}/${CLEAN_PREFIX}/${SESSION_PREFIX}/"

INTERVAL="${OUTPUT_SYNC_INTERVAL:-60}"
MIRROR="${OUTPUT_SYNC_MIRROR:-true}"
LOCKFILE="/tmp/comfy-output-sync.lock"

# One-instance lock
exec 9>"${LOCKFILE}"
flock -n 9 || { echo "[output-sync] Another instance running; exiting."; exit 0; }

mkdir -p "$LOCAL_DIR"

# Discover ComfyUI local port reliably
detect_port() {
  # shell function mirrors provisioning_detect_comfy_local_port logic inline
  if [[ -n "${COMFY_LOCAL_PORT:-}" ]]; then echo "${COMFY_LOCAL_PORT}"; return; fi
  if [[ -n "${COMFYUI_ARGS:-}" ]]; then
    awk '{
      for(i=1;i<=NF;i++){
        if($i=="--port"){print $(i+1); exit}
        if($i ~ /^--port=/){sub(/^--port=/,"",$i); print $i; exit}
      }
    }' <<< "${COMFYUI_ARGS}" && return
  fi
  if [[ -r /etc/portal.yaml ]]; then
    awk '
      BEGIN{found=0}
      /name: *ComfyUI/{found=1}
      found && /local_port:/{gsub(/[^0-9]/,""); if($0!=""){print $0; exit}}
    ' /etc/portal.yaml && return
  fi
  echo 18188
}

COMFY_PORT="$(detect_port)"
echo "[output-sync] Using ComfyUI local port: ${COMFY_PORT}"

# --- Wait for ComfyUI to answer on the detected port ---
echo "[output-sync] Waiting for ComfyUI on 127.0.0.1:${COMFY_PORT} ..."

is_ready() {
  # Try a few likely endpoints; accept 200, 401, or 404 as "up"
  for path in "/" "/api/version" "/api/queue"; do
    code="$(curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${COMFY_PORT}${path}" || echo 000)"
    case "$code" in
      200|401|404) return 0 ;;
    esac
  done
  return 1
}

# Try up to ~5 minutes before giving up
for _ in {1..100}; do
  if is_ready; then
    echo "[output-sync] ComfyUI is up on 127.0.0.1:${COMFY_PORT}. Starting sync..."
    break
  fi
  sleep 3
done

# Final check
if ! is_ready; then
  echo "[output-sync] ERROR: ComfyUI did not respond on 127.0.0.1:${COMFY_PORT}. Exiting."
  exit 1
fi

while true; do
  if [[ "${MIRROR,,}" == "true" ]]; then
    rclone sync "$LOCAL_DIR" "$REMOTE" \
      --checksum --transfers=4 --checkers=8 --fast-list \
      --retries=10 --low-level-retries=20 --retries-sleep=5s \
      --create-empty-src-dirs --s3-no-check-bucket --quiet
  else
    rclone copy "$LOCAL_DIR" "$REMOTE" \
      --checksum --transfers=4 --checkers=8 --fast-list \
      --retries=10 --low-level-retries=20 --retries-sleep=5s \
      --create-empty-src-dirs --s3-no-check-bucket --quiet
  fi
  echo "[output-sync] $(date -Is) tick -> ${REMOTE}"
  sleep "${INTERVAL}"
done
EOSH
    chmod +x "$daemon"

    nohup "$daemon" >/var/log/comfy-output-sync.log 2>&1 & disown || true
    echo "[output-sync] Daemon started. Log: /var/log/comfy-output-sync.log"
}



function provisioning_start() {
    provisioning_print_header
    provisioning_get_apt_packages
	# 1) Optional: install PyTorch (set TORCH_NIGHTLY=true to enable nightly build)
    provisioning_update_torch
	# 2) Force-update ComfyUI core to latest (unless AUTO_UPDATE=false)
    provisioning_update_comfyui
	if [[ -f "${COMFYUI_DIR}/requirements.txt" ]]; then
        pip install --no-cache-dir -r "${COMFYUI_DIR}/requirements.txt"
    fi
    provisioning_get_nodes
    provisioning_get_pip_packages
    provisioning_get_files \
        "${COMFYUI_DIR}/models/checkpoints" \
        "${CHECKPOINT_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/diffusion_models" \
        "${DIFFUSION_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/unet" \
        "${UNET_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/loras" \
        "${LORA_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/controlnet" \
        "${CONTROLNET_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/vae" \
        "${VAE_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/esrgan" \
        "${ESRGAN_MODELS[@]}"
	provisioning_get_files \
        "${COMFYUI_DIR}/models/upscale_models" \
        "${UPSCALE_MODELS[@]}"
	provisioning_get_files \
        "${COMFYUI_DIR}/models/latent_upscale_models" \
        "${LATENT_UPSCALE_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/clip" \
        "${CLIP_MODELS[@]}"
	provisioning_get_files \
        "${COMFYUI_DIR}/user/default/workflows" \
        "${WORKFLOWS[@]}"
	# Start background MinIO output sync daemon (waits for ComfyUI to be up)
    provisioning_setup_output_sync
	
    provisioning_print_end
}

function provisioning_get_apt_packages() {
    if [[ -n $APT_PACKAGES ]]; then
            sudo $APT_INSTALL ${APT_PACKAGES[@]}
    fi
}

function provisioning_get_pip_packages() {
    if [[ -n $PIP_PACKAGES ]]; then
            pip install --no-cache-dir ${PIP_PACKAGES[@]}
    fi
}

# Update ComfyUI core to the latest upstream (default branch auto-detected)
# Env vars:
#   COMFY_UPDATE=true|false (default: true)
#   COMFY_REPO=https://github.com/comfyanonymous/ComfyUI.git
#   COMFY_RECLONE=true|false (default: false; if true & not a git repo, reclone)
function provisioning_update_comfyui() {
    # Respect COMFY_UPDATE=false to opt-out
    if [[ ${COMFY_UPDATE,,} == "false" ]]; then
        printf "COMFY_UPDATE=false; skipping ComfyUI core update.\n"
        return 0
    fi

    local repo="${COMFY_REPO:-https://github.com/comfyanonymous/ComfyUI.git}"
    local dir="$COMFYUI_DIR"

    # If the dir exists but isn't a git repo
    if [[ ! -d "$dir/.git" ]]; then
        if [[ ${COMFY_RECLONE,,} == "true" ]]; then
            printf "ComfyUI at %s is not a git repo; recloning from %s ...\n" "$dir" "$repo"
            rm -rf "$dir"
            git clone --recursive "$repo" "$dir"
        else
            printf "ComfyUI directory not a git repo (or missing): %s — skipping core update.\n" "$dir"
            return 0
        fi
    fi

    # Now guaranteed to be a git repo
    (
        cd "$dir"

        # Make sure origin points to the requested repo
        local current_url
        current_url="$(git remote get-url origin 2>/dev/null || true)"
        if [[ "$current_url" != "$repo" && -n "$current_url" ]]; then
            printf "Resetting origin remote to %s (was %s)\n" "$repo" "$current_url"
            git remote set-url origin "$repo"
        elif [[ -z "$current_url" ]]; then
            git remote add origin "$repo"
        fi

        # Fetch everything and detect origin's default branch
        git fetch --all --tags --prune

        # Most reliable: read origin/HEAD symref
        local default_branch
        default_branch="$(git ls-remote --symref origin HEAD 2>/dev/null \
                          | awk '/^ref:/ {sub(/^refs\/heads\//,"",$2); print $2; exit}')"
        if [[ -z "$default_branch" ]]; then
            default_branch="$(git remote show origin | awk '/HEAD branch:/ {print $3; exit}')"
        fi
        [[ -z "$default_branch" ]] && default_branch="master"

        printf "Updating ComfyUI -> origin/%s\n" "$default_branch"
        git reset --hard "origin/${default_branch}"

        printf "ComfyUI now at: "
        git log -1 --date=iso --pretty='format:%h %cd %s%n'
    )
}


# Optional: install/update PyTorch depending on env vars
function provisioning_update_torch() {
    if [[ ${UPDATE_TORCH,,} != "true" ]]; then
        printf "UPDATE_TORCH not enabled; skipping PyTorch update.\n"
        return 0
    fi

    # Uninstall old torch wheels first
    pip uninstall -y torch torchvision torchaudio >/dev/null 2>&1 || true

    if [[ ${TORCH_NIGHTLY,,} == "true" ]]; then
        printf "Installing PyTorch nightly cu129...\n"
        pip install --no-cache-dir --pre -U torch torchvision torchaudio \
            --index-url https://download.pytorch.org/whl/nightly/cu129
    else
        printf "Installing PyTorch stable cu129...\n"
        pip install --no-cache-dir -U torch torchvision torchaudio \
            --extra-index-url https://download.pytorch.org/whl/cu129
    fi

    python - <<'PY'
import torch
print("Torch version:", torch.__version__)
print("CUDA available:", torch.cuda.is_available())
print("torch.version.cuda:", torch.version.cuda)
PY
}

function provisioning_get_nodes() {
    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"
        path="${COMFYUI_DIR}/custom_nodes/${dir}"
        requirements="${path}/requirements.txt"
        if [[ -d $path ]]; then
            if [[ ${AUTO_UPDATE,,} != "false" ]]; then
                printf "Updating node: %s...\n" "${repo}"
                ( cd "$path" && git pull )
                if [[ -e $requirements ]]; then
                   pip install --no-cache-dir -r "$requirements"
                fi
            fi
        else
            printf "Downloading node: %s...\n" "${repo}"
            git clone "${repo}" "${path}" --recursive
            if [[ -e $requirements ]]; then
                pip install --no-cache-dir -r "${requirements}"
            fi
        fi
    done
}

function provisioning_get_files() {
    if [[ -z $2 ]]; then return 1; fi
    
    dir="$1"
    shift
    arr=("$@")
    printf "Downloading %s model(s) to %s...\n" "${#arr[@]}" "$dir"
    for url in "${arr[@]}"; do
        printf "Downloading: %s\n" "${url}"
        provisioning_download "${url}" "${dir}"
        printf "\n"
    done
}

function provisioning_print_header() {
    printf "\n##############################################\n#             #\n#      Provisioning container       #\n#             #\n#      This will take some time     #\n#             #\n# Your container will be ready on completion #\n#             #\n##############################################\n\n"
}

function provisioning_print_end() {
    printf "\nProvisioning complete:  Application will start now\n\n"
}

function provisioning_has_valid_hf_token() {
    [[ -n "$HF_TOKEN" ]] || return 1
    url="https://huggingface.co/api/whoami-v2"

    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $HF_TOKEN" \
        -H "Content-Type: application/json")

    # Check if the token is valid
    if [ "$response" -eq 200 ]; then
        return 0
    else
        return 1
    fi
}

function provisioning_has_valid_civitai_token() {
    [[ -n "$CIVITAI_TOKEN" ]] || return 1
    url="https://civitai.com/api/v1/models?hidden=1&limit=1"

    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $CIVITAI_TOKEN" \
        -H "Content-Type: application/json")

    # Check if the token is valid
    if [ "$response" -eq 200 ]; then
        return 0
    else
        return 1
    fi
}

# Download from $1 URL to $2 file path
function provisioning_download() {
    local url="$1"
    local dest_dir="$2"
    local auth_token=""
    
    # Check if it's a Hugging Face URL and if a token is available
    if [[ -n "$HF_TOKEN" && "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$) ]]; then
        auth_token="$HF_TOKEN"
    # Check if it's a Civitai URL and if a token is available
    elif [[ -n "$CIVITAI_TOKEN" && "$url" =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$) ]]; then
        auth_token="$CIVITAI_TOKEN"
    fi

    # Extract the path from the URL to create a subdirectory
    local url_path="${url#*://*/}"
    local path_without_filename="${url_path%/*}"
    local full_dest_dir="${dest_dir}/${path_without_filename}"
    
    mkdir -p "${full_dest_dir}"

    if [[ -n $auth_token ]]; then
        wget --header="Authorization: Bearer $auth_token" -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "${full_dest_dir}" "$url"
    else
        wget -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "${full_dest_dir}" "$url"
    fi
}

# Allow user to disable provisioning if they started with a script they didn't want
if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi