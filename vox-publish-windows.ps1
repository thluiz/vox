# vox-publish-windows.ps1 — equivalente ao vox-publish.sh mas corre no Windows
param(
    [switch]$SkipPull
)

$ErrorActionPreference = "Stop"

$VOX_DIR      = "E:\vox"
$QUARTZ_DIR   = "E:\quartz"
$CONTENT_DIR  = "E:\vox-content"
$SCRIPTS_DIR  = $VOX_DIR

# Carregar .env
$envFile = Join-Path $VOX_DIR ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim().Trim('"')
            [Environment]::SetEnvironmentVariable($key, $val, "Process")
        }
    }
}

if (-not $env:AWS_ACCESS_KEY_ID -or -not $env:AWS_SECRET_ACCESS_KEY) {
    throw "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY nao definidos — verifique E:\vox\.env"
}
if (-not $env:AWS_CF_DISTRIBUTION_ID) {
    throw "AWS_CF_DISTRIBUTION_ID nao definido — verifique E:\vox\.env"
}

$env:AWS_DEFAULT_REGION = if ($env:AWS_REGION) { $env:AWS_REGION } else { "sa-east-1" }
$aws = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'

if (-not $SkipPull) {
    Write-Host "[vox] Atualizando vox-content..."
    git -C $CONTENT_DIR pull --ff-only
    Write-Host "[vox] Atualizando vox config..."
    git -C $VOX_DIR pull --ff-only 2>$null
}

# Copiar configs para o Quartz
Write-Host "[vox] Syncing config files to Quartz..."
Copy-Item "$VOX_DIR\quartz.config.ts" "$QUARTZ_DIR\quartz.config.ts" -Force
Copy-Item "$VOX_DIR\quartz.layout.ts" "$QUARTZ_DIR\quartz.layout.ts" -Force
Copy-Item "$VOX_DIR\custom.scss"      "$QUARTZ_DIR\quartz\styles\custom.scss" -Force

# Aplicar patches
$patchesDir = "$VOX_DIR\patches"
$patches = Get-ChildItem "$patchesDir\*.patch" -ErrorAction SilentlyContinue
if ($patches) {
    Write-Host "[vox] Applying Quartz patches..."
    # Reverter primeiro (caso run anterior tenha falhado)
    foreach ($p in $patches) {
        git -C $QUARTZ_DIR apply --reverse --ignore-whitespace $p.FullName 2>$null
    }
    foreach ($p in $patches) {
        $check = git -C $QUARTZ_DIR apply --ignore-whitespace --check $p.FullName 2>&1
        if ($LASTEXITCODE -eq 0) {
            git -C $QUARTZ_DIR apply --ignore-whitespace $p.FullName
            Write-Host "  applied: $($p.Name)"
        } else {
            Write-Error "  FAILED: $($p.Name) — patch does not apply cleanly"
            exit 1
        }
    }
}

# Build
Write-Host "[vox] Build Quartz..."
Set-Location $QUARTZ_DIR
$env:CONTENT_DIR = $CONTENT_DIR

# Atualizar home page
python "$SCRIPTS_DIR\update-vox-home.py"

# Commitar index.md se alterado
$diff = git -C $CONTENT_DIR diff --quiet index.md 2>$null
if ($LASTEXITCODE -ne 0) {
    git -C $CONTENT_DIR add index.md
    git -C $CONTENT_DIR commit -m "chore: update index.md (top tags + recent posts)" --quiet
    git -C $CONTENT_DIR push --quiet
}

# Limpar public antes do build para evitar EBUSY (Windows Search/Defender bloqueando ficheiros antigos)
$publicDir = "$QUARTZ_DIR\public"
if (Test-Path $publicDir) {
    Write-Host "[vox] Limpando public/..."
    Remove-Item $publicDir -Recurse -Force -ErrorAction SilentlyContinue
}

npx quartz build
if ($LASTEXITCODE -ne 0) {
    throw "[vox] Build falhou (exit $LASTEXITCODE) — abortando deploy"
}

# Copiar ficheiros estáticos raiz
Copy-Item "$QUARTZ_DIR\quartz\static\robots.txt" "$QUARTZ_DIR\public\robots.txt" -Force -ErrorAction SilentlyContinue

# Reverter patches
if ($patches) {
    Write-Host "[vox] Reverting Quartz patches..."
    foreach ($p in $patches) {
        git -C $QUARTZ_DIR apply --reverse --ignore-whitespace $p.FullName 2>$null
    }
}

# Deploy S3 + CloudFront
Write-Host "[vox] Sync para S3..."
& $aws s3 sync "$QUARTZ_DIR\public" s3://hermes-vox-br `
    --delete `
    --cache-control "public, max-age=3600" `
    --exclude "*.DS_Store"
if ($LASTEXITCODE -ne 0) { throw "[vox] aws s3 sync falhou" }

Write-Host "[vox] Invalidando cache CloudFront..."
& $aws cloudfront create-invalidation `
    --distribution-id $env:AWS_CF_DISTRIBUTION_ID `
    --paths "/*" | Out-Null

# Push vox-content
Write-Host "[vox] Pushing vox-content..."
git -C $CONTENT_DIR push

Write-Host "[vox] Publicado com sucesso!"
