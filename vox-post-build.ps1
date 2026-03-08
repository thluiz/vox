# vox-post-build.ps1
# Após npx quartz build: cria slug/index.html para cada slug.html
# Permite que Azure Blob Storage sirva /slug/ sem CDN ou extensão explícita.
param(
    [string]$PublicDir = "E:\quartz\public"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $PublicDir)) {
    throw "PublicDir não encontrado: $PublicDir"
}

$files = Get-ChildItem $PublicDir -Recurse -Filter "*.html" |
    Where-Object { $_.Name -ne "index.html" }

$count = 0
foreach ($file in $files) {
    $slugDir = $file.FullName -replace '\.html$', ''
    $dest    = Join-Path $slugDir "index.html"

    if (-not (Test-Path $slugDir)) {
        New-Item -ItemType Directory -Path $slugDir | Out-Null
    }

    # Só copia se não existir ou se o source for mais recente
    if (-not (Test-Path $dest) -or ($file.LastWriteTime -gt (Get-Item $dest).LastWriteTime)) {
        Copy-Item $file.FullName $dest -Force
        $count++
    }
}

Write-Host "[post-build] $count slug/index.html criados em $PublicDir"
