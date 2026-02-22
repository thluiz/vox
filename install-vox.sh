#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Carrega .env local (NÃO commitado)
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
else
  echo "AVISO: $SCRIPT_DIR/.env nao encontrado."
  echo "Crie-o a partir de .env.example e preencha os valores."
  echo "Continuando com defaults e vars de ambiente ja exportadas..."
fi

# Vars com defaults
VOX_DIR="${VOX_DIR:-${HOME}/vox}"
QUARTZ_DIR="${QUARTZ_DIR:-${HOME}/quartz}"
CONTENT_DIR="${CONTENT_DIR:-${HOME}/vox-content}"

# Valida vars obrigatorias
: "${VOX_CONTENT_REPO:?VOX_CONTENT_REPO nao definido — verifique .env}"

echo "[vox] Instalando Vox em $QUARTZ_DIR / $CONTENT_DIR"

# 1. Clone ou atualiza vox-content
if [[ ! -d "$CONTENT_DIR/.git" ]]; then
  echo "[vox] Clonando vox-content..."
  git clone "$VOX_CONTENT_REPO" "$CONTENT_DIR"
else
  echo "[vox] vox-content ja existe, pulando clone."
fi

# 2. Clone Quartz v4 (core intocado)
if [[ ! -d "$QUARTZ_DIR/.git" ]]; then
  echo "[vox] Clonando Quartz v4..."
  git clone https://github.com/jackyzha0/quartz.git "$QUARTZ_DIR"
else
  echo "[vox] Quartz ja existe, pulando clone."
fi

# 3. npm install
echo "[vox] npm install no Quartz..."
cd "$QUARTZ_DIR"
npm install

# 4. Copy config files into Quartz (symlinks break esbuild relative import resolution)
#    Only content/ uses a symlink — markdown files don't have Node.js imports.
echo "[vox] Copiando config files para Quartz..."
cp "$VOX_DIR/quartz.config.ts" "$QUARTZ_DIR/quartz.config.ts"
cp "$VOX_DIR/quartz.layout.ts" "$QUARTZ_DIR/quartz.layout.ts"
mkdir -p "$QUARTZ_DIR/quartz/styles"
cp "$VOX_DIR/custom.scss"      "$QUARTZ_DIR/quartz/styles/custom.scss"

# 5. Symlink: content/ → vox-content
# Remove link/dir anterior se existir
if [[ -L "$QUARTZ_DIR/content" ]]; then
  rm "$QUARTZ_DIR/content"
elif [[ -d "$QUARTZ_DIR/content" ]]; then
  echo "ERRO: $QUARTZ_DIR/content existe como diretorio real. Remova manualmente."
  exit 1
fi
ln -sf "$CONTENT_DIR" "$QUARTZ_DIR/content"

# 6. vox-publish no PATH
chmod +x "$VOX_DIR/vox-publish.sh"
mkdir -p "${HOME}/.local/bin"
ln -sf "$VOX_DIR/vox-publish.sh" "${HOME}/.local/bin/vox-publish"

# Garante ~/.local/bin no PATH
if ! grep -q '\.local/bin' "${HOME}/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"
  echo "[vox] PATH atualizado em ~/.bashrc"
fi

echo ""
echo "✓ Vox instalado com sucesso!"
echo "  Build + deploy: vox-publish"
echo "  Build local:    cd $QUARTZ_DIR && npx quartz build --serve"
