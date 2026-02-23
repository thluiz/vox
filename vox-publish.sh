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

# 3. Copy config files (not symlinks — esbuild resolves symlink to real path
#    breaking relative imports like "./quartz/plugins")
echo "[vox] Syncing config files to Quartz..."
cp "$VOX_DIR/quartz.config.ts" "$QUARTZ_DIR/quartz.config.ts"
cp "$VOX_DIR/quartz.layout.ts" "$QUARTZ_DIR/quartz.layout.ts"
cp "$VOX_DIR/custom.scss"      "$QUARTZ_DIR/quartz/styles/custom.scss"

# 3b. Apply Quartz patches (cosmetic/site-specific tweaks — see README)
PATCHES_DIR="$VOX_DIR/patches"
if [[ -d "$PATCHES_DIR" ]] && ls "$PATCHES_DIR"/*.patch &>/dev/null; then
  echo "[vox] Applying Quartz patches..."
  for p in "$PATCHES_DIR"/*.patch; do
    if git -C "$QUARTZ_DIR" apply --check "$p" 2>/dev/null; then
      git -C "$QUARTZ_DIR" apply "$p"
      echo "  applied: $(basename "$p")"
    else
      echo "  FAILED: $(basename "$p") — patch does not apply cleanly" >&2
      echo "  Quartz may have been updated. Regenerate the patch." >&2
      exit 1
    fi
  done
fi

# 4. Build
echo "[vox] Build Quartz..."
cd "$QUARTZ_DIR"

# Atualiza home page (publicações recentes + top tags) — sem IA
python3 "$SCRIPT_DIR/update-vox-home.py"

# Commita index.md se foi alterado pelo update-vox-home
if ! git -C "$CONTENT_DIR" diff --quiet index.md 2>/dev/null; then
  git -C "$CONTENT_DIR" add index.md
  git -C "$CONTENT_DIR" commit -m "chore: update index.md (top tags + recent posts)" --quiet
  git -C "$CONTENT_DIR" push --quiet
fi

npx quartz build

# Copy root-level static files (Quartz puts static/ → public/static/, not root)
cp "$QUARTZ_DIR/quartz/static/robots.txt" "$QUARTZ_DIR/public/robots.txt" 2>/dev/null || true

# 4b. Revert patches (keep Quartz checkout clean for future git pull)
if [[ -d "$PATCHES_DIR" ]] && ls "$PATCHES_DIR"/*.patch &>/dev/null; then
  echo "[vox] Reverting Quartz patches..."
  for p in "$PATCHES_DIR"/*.patch; do
    git -C "$QUARTZ_DIR" apply --reverse "$p" 2>/dev/null || true
  done
fi

# 4. Deploy — Azure Static Web Apps
echo "[vox] Deploy Azure SWA..."
: "${AZURE_SWA_TOKEN:?AZURE_SWA_TOKEN nao definido — verifique .env}"
swa deploy ./public \
  --deployment-token "$AZURE_SWA_TOKEN" \
  --env production

echo "[vox] Publicado com sucesso!"
