#!/usr/bin/env bash
#
# Install and start MoneyPrinterTurbo on a Jetson Orin (aarch64 / NVIDIA L4T).
#
# Run this ON the Jetson, from a checkout of this repository:
#
#   ./scripts/install-jetson.sh
#
# It performs the host-side steps that a bare `docker compose up` cannot do:
# checking the platform and the nvidia container runtime, creating config.toml
# and the bind-mount directories before Docker turns them into root-owned
# directories, picking the l4t-jetpack tag matching this board, and writing .env
# with this host's LAN address and the chosen ports.
#
# Re-running is safe: existing config.toml, .env and storage are left alone.

set -euo pipefail

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly COMPOSE_BASE="docker-compose.jetson.yml"
readonly COMPOSE_GPU="docker-compose.jetson-gpu.yml"

# l4t-jetpack tags published on nvcr.io. An exact match is used when available,
# otherwise the newest tag sharing the board's major L4T release.
readonly KNOWN_L4T_TAGS=(
    "r36.4.0" "r36.3.0" "r36.2.0"
    "r35.4.1" "r35.3.1" "r35.2.1" "r35.1.0"
)

WEBUI_PORT="${MPT_WEBUI_PORT:-3200}"
API_PORT="${MPT_API_PORT:-8200}"
BIND_ADDR="${MPT_BIND_ADDR:-0.0.0.0}"
GPU_BUILD=0
START=1
OLLAMA_CLOUD=0
readonly OLLAMA_CLOUD_BASE_URL="https://ollama.com/v1"

log()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m  !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: scripts/install-jetson.sh [options]

  --webui-port PORT   Host port for the WebUI (default 3200)
  --api-port PORT     Host port for the API (default 8200)
  --bind ADDR         Address the ports bind to (default 0.0.0.0; use
                      127.0.0.1 to keep the stack off the LAN)
  --gpu-build         Build the CUDA image from Dockerfile.jetson instead of
                      pulling the prebuilt arm64 release image. Slow; see
                      docs/jetson-orin.md before choosing it.
  --ollama-cloud      Configure Ollama Cloud (ollama.com) as the LLM provider.
                      Reads the key from $OLLAMA_API_KEY, or prompts for it,
                      then lists the models your subscription can reach so you
                      can pick one. Never pass the key as an argument — it
                      would land in your shell history.
  --no-start          Prepare config.toml, .env and directories, then stop
                      without pulling or starting containers.
  -h, --help          Show this help.

Environment:
  OLLAMA_API_KEY      Ollama Cloud API key, used by --ollama-cloud.
  OLLAMA_MODEL        Cloud model id to select non-interactively.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --webui-port) WEBUI_PORT="${2:?--webui-port needs a value}"; shift 2 ;;
        --api-port)   API_PORT="${2:?--api-port needs a value}"; shift 2 ;;
        --bind)       BIND_ADDR="${2:?--bind needs a value}"; shift 2 ;;
        --gpu-build)  GPU_BUILD=1; shift ;;
        --ollama-cloud) OLLAMA_CLOUD=1; shift ;;
        --no-start)   START=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; die "unknown option: $1" ;;
    esac
done

cd "$REPO_DIR"

# --------------------------------------------------------------------------
# Host checks
# --------------------------------------------------------------------------

check_platform() {
    log "Checking platform"
    local arch
    arch="$(uname -m)"
    [[ "$arch" == "aarch64" ]] || die "expected aarch64, found $arch. This script targets Jetson hardware; use docker-compose.yml or docker-compose.gpu.yml elsewhere."

    if [[ -r /proc/device-tree/model ]]; then
        ok "board: $(tr -d '\0' < /proc/device-tree/model)"
    elif [[ -r /etc/nv_tegra_release ]]; then
        ok "L4T host detected"
    else
        warn "no Tegra markers found (/proc/device-tree/model, /etc/nv_tegra_release). Continuing, but this may not be a Jetson."
    fi
}

check_docker() {
    log "Checking Docker"
    command -v docker >/dev/null 2>&1 || die "docker is not installed. On JetPack: sudo apt-get install -y docker.io docker-compose-v2"
    docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon. Start it (sudo systemctl start docker) or add yourself to the docker group (sudo usermod -aG docker ${USER:-$(id -un)}, then log out and back in)."
    docker compose version >/dev/null 2>&1 || die "the 'docker compose' plugin is missing. Install it with: sudo apt-get install -y docker-compose-v2"
    ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), compose plugin present"
}

# The compose file requests `runtime: ${MPT_RUNTIME:-nvidia}`. Without the
# runtime registered, `up` fails outright, so it is checked before anything is
# created and .env is written with a runtime that actually exists.
check_nvidia_runtime() {
    log "Checking NVIDIA container runtime"
    if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
        ok "nvidia runtime registered"
        return 0
    fi
    warn "the nvidia container runtime is not registered with Docker."
    warn "Install it with: sudo apt-get install -y nvidia-container-toolkit && sudo systemctl restart docker"
    warn "Falling back to MPT_RUNTIME=runc: the stack still runs, but without GPU access."
    return 1
}

# --------------------------------------------------------------------------
# L4T / base image
# --------------------------------------------------------------------------

detect_l4t_tag() {
    local major="" minor="" patch="" detected=""
    local release_file="${L4T_RELEASE_FILE:-/etc/nv_tegra_release}"

    if [[ -r "$release_file" ]]; then
        # Example: "# R36 (release), REVISION: 4.0, GCID: ..., BOARD: generic"
        local line
        line="$(head -n 1 "$release_file")"
        major="$(sed -n 's/^#\? *R\([0-9]\+\).*/\1/p' <<<"$line")"
        minor="$(sed -n 's/.*REVISION: \([0-9]\+\)\.\([0-9]\+\).*/\1/p' <<<"$line")"
        patch="$(sed -n 's/.*REVISION: \([0-9]\+\)\.\([0-9]\+\).*/\2/p' <<<"$line")"
    fi

    if [[ -z "$major" ]] && command -v dpkg-query >/dev/null 2>&1; then
        local ver
        ver="$(dpkg-query --show --showformat='${Version}' nvidia-l4t-core 2>/dev/null || true)"
        if [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
            major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"
        fi
    fi

    [[ -n "$major" && -n "$minor" && -n "$patch" ]] || return 1
    detected="r${major}.${minor}.${patch}"

    local tag
    for tag in "${KNOWN_L4T_TAGS[@]}"; do
        [[ "$tag" == "$detected" ]] && { printf '%s' "$tag"; return 0; }
    done
    # No exact tag: newest published tag with the same major release. CUDA
    # userspace is compatible within an L4T major release.
    for tag in "${KNOWN_L4T_TAGS[@]}"; do
        if [[ "$tag" == "r${major}."* ]]; then
            warn "L4T $detected has no matching l4t-jetpack tag; falling back to $tag"
            printf '%s' "$tag"
            return 0
        fi
    done
    return 1
}

# --------------------------------------------------------------------------
# Host address and ports
# --------------------------------------------------------------------------

detect_lan_ip() {
    local ip=""
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
    [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    printf '%s' "${ip:-127.0.0.1}"
}

port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn "( sport = :$port )" 2>/dev/null | tail -n +2 | grep -q . && return 0
        return 1
    fi
    return 1
}

check_ports() {
    log "Checking ports"
    local port conflict=0
    for port in "$WEBUI_PORT" "$API_PORT"; do
        if port_in_use "$port"; then
            # An earlier run of this stack owning the port is not a conflict.
            if docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -q "moneyprinterturbo.*:${port}->"; then
                ok "port $port already served by this stack"
            else
                warn "port $port is already in use by another service"
                conflict=1
            fi
        else
            ok "port $port free"
        fi
    done
    [[ "$conflict" -eq 0 ]] || die "pick different ports with --webui-port/--api-port, or stop the service holding them."
}

# --------------------------------------------------------------------------
# Files Docker would otherwise create as root-owned directories
# --------------------------------------------------------------------------

prepare_files() {
    local host_ip="$1" l4t_tag="$2" runtime="$3"

    log "Preparing config.toml, storage and models"

    # A bind mount whose source is missing is created by Docker as a directory.
    # config.toml must exist as a file before the first `up`.
    if [[ -d config.toml ]]; then
        die "config.toml exists as a directory (created by an earlier 'docker compose up' before the file existed). Remove it with: sudo rmdir config.toml"
    fi
    if [[ -f config.toml ]]; then
        ok "config.toml already present, left unchanged"
    else
        cp config.example.toml config.toml
        # Download links returned by the API must point at the published port,
        # not at the container's internal 8080.
        sed -i "s|^endpoint = \"\"|endpoint = \"http://${host_ip}:${API_PORT}\"|" config.toml
        ok "config.toml created from config.example.toml (endpoint -> http://${host_ip}:${API_PORT})"
    fi

    mkdir -p storage models
    ok "storage/ and models/ ready"

    if [[ -f .env ]]; then
        ok ".env already present, left unchanged (delete it to regenerate)"
    else
        cat > .env <<EOF
# Written by scripts/install-jetson.sh. See .env.jetson.example for the
# meaning of each value.
MPT_WEBUI_PORT=${WEBUI_PORT}
MPT_API_PORT=${API_PORT}
MPT_BIND_ADDR=${BIND_ADDR}
MPT_HOST=${host_ip}
MPT_RUNTIME=${runtime}
L4T_BASE_IMAGE=nvcr.io/nvidia/l4t-jetpack:${l4t_tag}
EOF
        ok ".env written (webui ${WEBUI_PORT}, api ${API_PORT}, bind ${BIND_ADDR}, runtime ${runtime})"
    fi
}

# --------------------------------------------------------------------------
# Ollama Cloud
# --------------------------------------------------------------------------

# Rewrites simple top-level `key = "value"` entries in config.toml. Done in
# Python rather than sed because API keys are arbitrary strings that would need
# escaping in a sed replacement.
set_config_value() {
    local key="$1" value="$2"
    CONFIG_KEY="$key" CONFIG_VALUE="$value" python3 - <<'PY'
import os
import re

key = os.environ["CONFIG_KEY"]
value = os.environ["CONFIG_VALUE"]
encoded = '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

with open("config.toml", encoding="utf-8") as handle:
    lines = handle.readlines()

pattern = re.compile(rf"^(\s*)#?\s*{re.escape(key)}\s*=")
for index, line in enumerate(lines):
    if pattern.match(line):
        indent = pattern.match(line).group(1)
        lines[index] = f"{indent}{key} = {encoded}\n"
        break
else:
    raise SystemExit(f"key not found in config.toml: {key}")

with open("config.toml", "w", encoding="utf-8") as handle:
    handle.writelines(lines)
PY
}

# Lists the models the subscription can actually reach. The hosted catalog
# changes over time, so the model is chosen from live data instead of being
# hardcoded here or in the provider registry.
fetch_ollama_cloud_models() {
    local api_key="$1"
    curl -fsS --max-time 20 -H "Authorization: Bearer ${api_key}" \
        "${OLLAMA_CLOUD_BASE_URL}/models" 2>/dev/null |
        python3 -c 'import json,sys
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ids = sorted({m.get("id","").strip() for m in payload.get("data", []) if isinstance(m, dict)} - {""})
print("\n".join(ids))'
}

configure_ollama_cloud() {
    log "Configuring Ollama Cloud as the LLM provider"

    command -v python3 >/dev/null 2>&1 || {
        warn "python3 not found on the host; skipping. Set llm_provider and ollama_cloud_api_key in config.toml by hand."
        return 0
    }
    command -v curl >/dev/null 2>&1 || {
        warn "curl not found on the host; skipping. Set llm_provider and ollama_cloud_api_key in config.toml by hand."
        return 0
    }

    local api_key="${OLLAMA_API_KEY:-}"
    if [[ -z "$api_key" ]]; then
        if [[ -t 0 ]]; then
            # Read silently so the key never appears on screen or in history.
            read -rsp "  Ollama Cloud API key (https://ollama.com/settings/keys): " api_key
            echo
        else
            warn "no OLLAMA_API_KEY set and no terminal to prompt on; skipping Ollama Cloud setup."
            return 0
        fi
    fi
    [[ -n "$api_key" ]] || { warn "empty API key; skipping Ollama Cloud setup."; return 0; }

    local models model
    models="$(fetch_ollama_cloud_models "$api_key" || true)"

    if [[ -z "$models" ]]; then
        # Could be a bad key, an expired subscription, or no route to
        # ollama.com. Configure anyway so the WebUI's connection test can
        # report the real reason.
        warn "could not list models from ${OLLAMA_CLOUD_BASE_URL}/models."
        warn "Check the key and the subscription; the WebUI's 'Test LLM Connection' button will show the exact error."
        model="${OLLAMA_MODEL:-}"
    else
        ok "$(wc -l <<<"$models") cloud models available"
        if [[ -n "${OLLAMA_MODEL:-}" ]]; then
            model="$OLLAMA_MODEL"
            grep -qxF "$model" <<<"$models" || warn "OLLAMA_MODEL='$model' is not in the catalog; configuring it anyway."
        elif [[ -t 0 ]]; then
            local -a options
            mapfile -t options <<<"$models"
            echo
            local i
            for i in "${!options[@]}"; do
                printf '   %2d) %s\n' "$((i + 1))" "${options[$i]}"
            done
            local choice=""
            read -rp "  Model number [1]: " choice
            choice="${choice:-1}"
            if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
                model="${options[$((choice - 1))]}"
            else
                warn "invalid selection '$choice'; using ${options[0]}"
                model="${options[0]}"
            fi
        else
            model="$(head -n 1 <<<"$models")"
            ok "no terminal to prompt on; selecting the first model: $model"
        fi
    fi

    set_config_value "llm_provider" "ollama_cloud"
    set_config_value "ollama_cloud_api_key" "$api_key"
    set_config_value "ollama_cloud_base_url" "$OLLAMA_CLOUD_BASE_URL"
    [[ -n "$model" ]] && set_config_value "ollama_cloud_model_name" "$model"

    ok "llm_provider = ollama_cloud${model:+, model = $model}"
    if [[ -z "$model" ]]; then
        warn "no model selected; pick one in the WebUI under Basic Settings before generating."
    fi
}

# --------------------------------------------------------------------------
# Bring the stack up
# --------------------------------------------------------------------------

compose() {
    if [[ "$GPU_BUILD" -eq 1 ]]; then
        docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_GPU" "$@"
    else
        docker compose -f "$COMPOSE_BASE" "$@"
    fi
}

start_stack() {
    if [[ "$GPU_BUILD" -eq 1 ]]; then
        log "Building the CUDA image (this takes a long time on-device)"
        compose build
    else
        log "Pulling the arm64 release image"
        compose pull
    fi

    log "Starting containers"
    compose up -d
    compose ps
}

wait_for_webui() {
    local i
    command -v curl >/dev/null 2>&1 || return 0
    log "Waiting for the WebUI to answer"
    for i in $(seq 1 60); do
        if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${WEBUI_PORT}/_stcore/health" 2>/dev/null; then
            ok "WebUI healthy"
            return 0
        fi
        sleep 2
    done
    warn "the WebUI did not answer within 120s. Check logs with: docker compose -f $COMPOSE_BASE logs -f webui"
    return 1
}

main() {
    check_platform
    check_docker
    local runtime="nvidia"
    check_nvidia_runtime || runtime="runc"

    local host_ip l4t_tag
    host_ip="$(detect_lan_ip)"
    ok "host address: $host_ip"

    if l4t_tag="$(detect_l4t_tag)"; then
        ok "L4T base image: nvcr.io/nvidia/l4t-jetpack:${l4t_tag}"
    else
        l4t_tag="r36.4.0"
        warn "could not detect the L4T release; defaulting the CUDA build base to ${l4t_tag}. Edit L4T_BASE_IMAGE in .env if that is wrong."
    fi

    check_ports
    prepare_files "$host_ip" "$l4t_tag" "$runtime"

    if [[ "$OLLAMA_CLOUD" -eq 1 ]]; then
        configure_ollama_cloud
    fi

    if [[ "$START" -eq 0 ]]; then
        log "--no-start given; stopping before pull/up"
        return 0
    fi

    start_stack
    wait_for_webui || true

    cat <<EOF

  WebUI  http://${host_ip}:${WEBUI_PORT}
  API    http://${host_ip}:${API_PORT}
  Docs   http://${host_ip}:${API_PORT}/docs

  Logs   docker compose -f ${COMPOSE_BASE} logs -f
  Stop   docker compose -f ${COMPOSE_BASE} down

  The WebUI has no authentication and ${BIND_ADDR} exposes it to the LAN.
  Next step: open the WebUI and set your LLM and material API keys under
  Basic Settings, or edit config.toml directly. The "Test LLM Connection"
  button there confirms the provider end to end.
EOF
}

main "$@"
