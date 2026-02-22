#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Ensure fnm Node is in PATH (for non-interactive shells / systemd services)
FNM_NODE_BIN="${HOME}/.local/share/fnm/node-versions/v24.13.1/installation/bin"
if [[ -d "$FNM_NODE_BIN" ]]; then
  export PATH="$FNM_NODE_BIN:$PATH"
fi

# Carrega .env (não commitado)
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
fi

VOX_DIR="${VOX_DIR:-${HOME}/vox}"
QUARTZ_DIR="${QUARTZ_DIR:-${HOME}/quartz}"
CONTENT_DIR="${CONTENT_DIR:-${HOME}/vox-content}"

SKIP_PULL="${1:-}"

if [[ "$SKIP_PULL" != "--skip-pull" ]]; then
  # 1. Atualiza conteúdo
  echo "[vox] Atualizando vox-content..."
  git -C "$CONTENT_DIR" pull --ff-only

  # 2. Atualiza configs (puxa novos commits do vox se tiver)
  git -C "$VOX_DIR" pull --ff-only 2>/dev/null || true
fi

# 3. Build
echo "[vox] Build Quartz..."
cd "$QUARTZ_DIR"
npx quartz build

# 4. Deploy — Azure Static Web Apps
echo "[vox] Deploy Azure SWA..."
: "${AZURE_SWA_TOKEN:?AZURE_SWA_TOKEN nao definido — verifique .env}"
swa deploy ./public \
  --deployment-token "$AZURE_SWA_TOKEN" \
  --env production

echo "[vox] Publicado com sucesso!"
