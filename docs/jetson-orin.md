# Deploying on Jetson Orin

Deployment guide for NVIDIA Jetson Orin modules (AGX Orin, Orin NX, Orin Nano)
running JetPack 5 or 6. Everything here also applies to other Tegra boards
running L4T.

The stack listens on **3200 (WebUI)** and **8200 (API)** rather than the
upstream 8501/8080, so it can share a board with other projects.

## Why a separate compose file

`docker-compose.gpu.yml` targets discrete NVIDIA GPUs and does not work on
Jetson, for two independent reasons:

- It builds from `Dockerfile.gpu`, whose base image is `nvidia/cuda`. The arm64
  variants of that image target SBSA server platforms; they do not run against
  Tegra's integrated GPU.
- It requests the GPU through `deploy.resources.reservations.devices`. On
  Tegra the integrated GPU is provided by the `nvidia` container *runtime*
  instead, which JetPack installs as `nvidia-container-toolkit`.

`docker-compose.jetson.yml` fixes both: it uses `runtime: nvidia`, and it
defaults to the published multi-arch release image, which already includes a
`linux/arm64` build (see `.github/workflows/docker-ghcr.yml`). Nothing is
compiled on the board.

That release image ships **upstream's** application code, so this checkout is
mounted over it at `/MoneyPrinterTurbo` (the same arrangement as the upstream
`docker-compose.yml`). Dependencies and ffmpeg come from the image; the code
that runs comes from this repository. Without that mount, anything added here —
the Ollama Cloud provider, for one — is absent from the container, and because
the WebUI silently resets an unrecognised `llm_provider` to the default, the
symptom is a provider that will not stay selected rather than a visible error.
`install-jetson.sh` checks for this after starting the stack.

If this checkout ever gains a new Python dependency, the image will not have it;
switch to the local build in `docker-compose.jetson-gpu.yml`, which installs
from `uv.lock`.

## What the GPU actually does here

Worth knowing before spending an evening on a CUDA build — this project has a
small GPU surface:

- **Subtitles.** `faster-whisper` (CTranslate2) is the only CUDA-capable
  dependency, and only when `subtitle_provider = "whisper"`. The default
  provider is `edge`, which is a network call. The CTranslate2 aarch64 wheels
  on PyPI are CPU-only builds, so `whisper.device = "cuda"` fails on Jetson
  even inside a CUDA container unless CTranslate2 is rebuilt from source with
  CUDA support for Tegra. Keep `device = "cpu"` and `compute_type = "int8"`.
- **Video encoding.** Final assembly runs through ffmpeg with `libx264` on the
  CPU. `video_codec = "h264_nvenc"` is accepted by the config but does not help
  here: Orin Nano has no NVENC block at all, and on Orin NX / AGX Orin the
  encoder is driven through V4L2 (`nvv4l2h264enc`), not ffmpeg's `h264_nvenc`.
  The encoder probe in `app/services/video.py` detects the missing encoder and
  falls back to `libx264` automatically, so setting it is harmless but pointless.
- **LLM, TTS and material search** are all remote API calls. No local inference.
  Script generation can run on [Ollama Cloud](#llm-provider-ollama-cloud), which
  keeps the heavy model off the board entirely.

So: **run the release image**. The CUDA path below exists so that CUDA, cuDNN
and TensorRT are present in the container if you later swap in a CUDA-enabled
CTranslate2 build — it does not make the stock stack faster.

### Why the release image runs under runc

Attaching the GPU is not free. On Tegra the nvidia container runtime works by
mounting the host's libraries into the container, and those are built against
the host's Ubuntu while the release image is Debian bullseye. The injected
libraries shadow the container's own, and ffmpeg then fails partway through a
render with:

```
/usr/bin/ffmpeg: error while loading shared libraries: libffi.so.8: cannot open shared object file
```

(bullseye ships `libffi.so.7`; Ubuntu 22.04 ships `libffi.so.8`). Since nothing
in that image can use the GPU, `docker-compose.jetson.yml` defaults to
`MPT_RUNTIME=runc` and asks only for `compute,utility` capabilities when the
runtime is used at all — `all` additionally injects the host EGL/GL stack, which
this workload never calls.

`docker-compose.jetson-gpu.yml` switches the runtime back on for its own image,
whose l4t-jetpack base matches the host userspace, so the same mounts are safe
there.

## Requirements

- Jetson Orin flashed with JetPack 5.x or 6.x
- Docker with the compose v2 plugin: `sudo apt-get install -y docker.io docker-compose-v2`
- The NVIDIA container runtime: `sudo apt-get install -y nvidia-container-toolkit`
  (preinstalled on most JetPack images)
- Your user in the `docker` group: `sudo usermod -aG docker $USER`, then log out
  and back in
- ~10 GB free disk for the release image path; considerably more for the CUDA
  build

Verify the runtime is registered:

```bash
docker info --format '{{json .Runtimes}}' | grep -o nvidia
```

`nvidia-smi` does not exist on Tegra — use `tegrastats` to watch GPU load.

## Quick start

On the Jetson:

```bash
git clone https://github.com/biali/MoneyPrinterTurbo.git
cd MoneyPrinterTurbo
git checkout claude/jetson-orin-docker-gpu-folzhi
./scripts/install-jetson.sh
```

The script checks the platform, Docker and the nvidia runtime, detects the
board's L4T release and LAN address, creates `config.toml`, `storage/`,
`models/` and `.env`, then pulls the arm64 image and starts both containers.
Re-running it leaves existing configuration alone.

Options: `--webui-port`, `--api-port`, `--bind`, `--gpu-build`, `--ollama-cloud`,
`--no-start`.

## Manual start

```bash
cp .env.jetson.example .env          # then edit MPT_HOST to this board's IP
cp config.example.toml config.toml   # must exist as a file before the first up
mkdir -p storage models
docker compose -f docker-compose.jetson.yml up -d
```

`config.toml` has to exist before the first `up`. It is a bind mount, and
Docker silently creates a root-owned *directory* in its place when the source
file is missing. If that already happened: `sudo rmdir config.toml`.

Then:

- WebUI — http://192.168.1.156:3200
- API — http://192.168.1.156:8200
- API docs — http://192.168.1.156:8200/docs

## Ports

Host ports come from `.env`; the containers keep their internal 8501/8080.

| Service | Host port | Container port | Variable |
| --- | --- | --- | --- |
| WebUI (Streamlit) | 3200 | 8501 | `MPT_WEBUI_PORT` |
| API (FastAPI) | 8200 | 8080 | `MPT_API_PORT` |

`MPT_BIND_ADDR` controls the bind address (`0.0.0.0` for LAN access,
`127.0.0.1` to keep the stack local). `MPT_HOST` is the address Streamlit
prints and builds browser URLs from — set it to the board's LAN IP.
`MPT_RUNTIME` selects the container runtime and defaults to `runc` on the
release-image path; see the note below before setting it to `nvidia`.

To move to different ports, edit `.env` and run
`docker compose -f docker-compose.jetson.yml up -d` again. Also update
`endpoint` in `config.toml` if you change the API port, since generated
download links are built from it.

**The WebUI has no authentication.** With `MPT_BIND_ADDR=0.0.0.0` anyone on the
LAN can reach it and read the API keys stored in `config.toml`. On an untrusted
network, set `MPT_BIND_ADDR=127.0.0.1` and tunnel:
`ssh -L 3200:127.0.0.1:3200 <user>@192.168.1.156`.

## LLM provider: Ollama Cloud

An [ollama.com](https://ollama.com) subscription is a good fit for this board.
Script and keyword generation is the one step that would otherwise want a big
local model, and the Orin has neither the memory nor the throughput for it —
`ollama_cloud` runs the model on Ollama's servers and leaves the Jetson doing
assembly and encoding.

The installer can set it up:

```bash
export OLLAMA_API_KEY=...   # from https://ollama.com/settings/keys
./scripts/install-jetson.sh --ollama-cloud
```

It lists the models your subscription can reach and asks which one to use, then
writes `llm_provider`, the key, the base URL and the model into `config.toml`.
Pass `OLLAMA_MODEL=<id>` to skip the prompt. If `OLLAMA_API_KEY` is unset the
script prompts for it with echo off, so the key never reaches your shell
history. Re-run it on an existing install to switch providers or models.

By hand, in `config.toml`:

```toml
[app]
llm_provider = "ollama_cloud"
ollama_cloud_api_key = "..."
ollama_cloud_base_url = "https://ollama.com/v1"
ollama_cloud_model_name = "gpt-oss:120b"
```

This is a separate provider from `ollama`. The local one needs no credential
and the service layer hardcodes a placeholder key for it, so it cannot carry a
real subscription key; the cloud one requires it. Use `ollama` for a model
running on your own machine, `ollama_cloud` for hosted ones.

In the WebUI, picking **Ollama Cloud** and entering the key loads the current
catalog for your account into the model dropdown, rather than relying on a
model name hardcoded in this repository. **Test LLM Connection** in the same
panel verifies the whole path — key, endpoint and model — before you generate
anything. Run it once after setup: it is the fastest way to confirm the
OpenAI-compatible endpoint is reachable from the Jetson.

## Configuration

Edit `config.toml` on the host (it is mounted into both containers) or use the
WebUI's Basic Settings panel. Restart after editing by hand:
`docker compose -f docker-compose.jetson.yml restart`.

Values that matter on this platform:

```toml
[app]
endpoint = "http://192.168.1.156:8200"   # must match the published API port
# video_codec = "libx264"                 # leave as-is; see the GPU section

[whisper]
device = "cpu"                            # CUDA CTranslate2 is unavailable on aarch64
compute_type = "int8"
model_size = "large-v3"                   # 'medium' or 'small' on 8 GB modules
```

Whisper models download to `models/` on the host, so they survive image
updates. `large-v3` in `int8` needs roughly 1.5 GB of RAM plus working memory —
tight alongside the rest of the stack on an 8 GB Orin Nano. Drop to `medium` or
`small` if the container is OOM-killed, or stay on the default
`subtitle_provider = "edge"`.

## CUDA build (optional)

Builds the image locally on top of `nvcr.io/nvidia/l4t-jetpack`, giving CUDA,
cuDNN and TensorRT inside the container. Read the GPU section first — this does
not accelerate the stock pipeline.

```bash
./scripts/install-jetson.sh --gpu-build
# or
docker compose -f docker-compose.jetson.yml -f docker-compose.jetson-gpu.yml up -d --build
```

The base image tag must match the board's L4T release, otherwise the CUDA
userspace and the host kernel driver disagree:

| L4T | JetPack | Tag |
| --- | --- | --- |
| R36.4 | 6.1 | `r36.4.0` |
| R36.3 | 6.0 | `r36.3.0` |
| R35.4.1 | 5.1.2 | `r35.4.1` |
| R35.3.1 | 5.1.1 | `r35.3.1` |

`cat /etc/nv_tegra_release` reports the release; `install-jetson.sh` detects it
and writes `L4T_BASE_IMAGE` into `.env`.

`Dockerfile.jetson` installs a standalone CPython 3.11 with `uv` and resolves
from `uv.lock`. The l4t-jetpack bases ship Ubuntu's default interpreter (3.10 on
r36, 3.8 on r35), both below this project's `requires-python`. Expect a long
first build; the base image alone is several GB.

## Operating

```bash
docker compose -f docker-compose.jetson.yml ps
docker compose -f docker-compose.jetson.yml logs -f webui
docker compose -f docker-compose.jetson.yml restart
docker compose -f docker-compose.jetson.yml down

# update to the latest release image
docker compose -f docker-compose.jetson.yml pull
docker compose -f docker-compose.jetson.yml up -d
```

Both services are `restart: always`, so they come back after a reboot once the
Docker daemon is enabled (`sudo systemctl enable docker`).

## Troubleshooting

**`ffmpeg: error while loading shared libraries: libffi.so.8`** during video
generation — the containers are running under the nvidia runtime, which mounted
the host's Ubuntu libraries over the release image's Debian ones. Fix it with:

```bash
sed -i 's/^MPT_RUNTIME=.*/MPT_RUNTIME=runc/' .env
docker compose -f docker-compose.jetson.yml up -d
```

Confirm afterwards with `docker compose -f docker-compose.jetson.yml exec -T
webui ffmpeg -version`. See "Why the release image runs under runc" above.

**`unknown or invalid runtime name: nvidia`** — the container toolkit is not
registered, and something set `MPT_RUNTIME=nvidia`. Either set it back to `runc`
in `.env`, or install the toolkit with `sudo apt-get install -y
nvidia-container-toolkit && sudo systemctl restart docker`.

**`manifest unknown` when pulling `nvcr.io/nvidia/l4t-jetpack`** — that tag is
not published. Check the current tag list at
https://catalog.ngc.nvidia.com/orgs/nvidia/containers/l4t-jetpack/tags and set
`L4T_BASE_IMAGE` in `.env` to the closest tag with the same major release. If
the pull is rejected rather than missing, run `docker login nvcr.io` first.

**`exec format error`** — an amd64 image was pulled. Confirm with
`docker image inspect ghcr.io/harry0703/moneyprinterturbo:latest --format '{{.Architecture}}'`;
it must be `arm64`. Force a refresh: `docker rmi ghcr.io/harry0703/moneyprinterturbo:latest`
then pull again.

**`config.toml` shows up as a directory** — the first `up` ran before the file
existed. `docker compose -f docker-compose.jetson.yml down && sudo rmdir
config.toml && cp config.example.toml config.toml`.

**Port already allocated** — another project holds 3200 or 8200. Change the
ports in `.env` and bring the stack up again.

**WebUI reachable on the Jetson but not from the LAN** — `MPT_BIND_ADDR` is
`127.0.0.1`, or the host firewall blocks the port
(`sudo ufw allow 3200/tcp`).

**Streamlit prints the wrong URL** — set `MPT_HOST` in `.env` to the board's
LAN address and restart.

**Ollama Cloud is missing from the LLM provider list, or the provider keeps
reverting to another one** — the containers are running upstream's code instead
of this checkout. Confirm with:

```bash
docker compose -f docker-compose.jetson.yml exec -T webui \
  python3 -c "from app.models.llm_provider import get_llm_provider; print(get_llm_provider('ollama_cloud'))"
```

`None` means the mount is missing. Check that `docker-compose.jetson.yml` still
maps `./:/MoneyPrinterTurbo`, then `docker compose -f docker-compose.jetson.yml
up -d`. The WebUI resets an `llm_provider` it does not recognise to the default
without warning, which is why this looks like a UI problem rather than a
deployment one.

**Container OOM-killed during subtitle generation** — Whisper model too large
for the module. Lower `whisper.model_size`, or switch
`subtitle_provider` back to `edge`.

**Video rendering is slow** — expected. Encoding is `libx264` on the Arm cores.
Run `sudo nvpmodel -m 0 && sudo jetson_clocks` for maximum clocks, and lower the
output resolution or clip count for faster turnaround.
