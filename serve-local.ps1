$ErrorActionPreference = "Stop"

$QUARTZ_DIR = "E:\quartz"
$VOX_DIR = "E:\vox"
$CONTENT_DIR = "E:\vox-content"

# fnm
$fnmExe = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\Schniz.fnm_Microsoft.Winget.Source_8wekyb3d8bbwe\fnm.exe"
if (Test-Path $fnmExe) {
    & $fnmExe env --shell powershell | Out-String | Invoke-Expression
}

# Copy configs
Copy-Item "$VOX_DIR\quartz.config.ts" "$QUARTZ_DIR\quartz.config.ts" -Force
Copy-Item "$VOX_DIR\quartz.layout.ts" "$QUARTZ_DIR\quartz.layout.ts" -Force
Copy-Item "$VOX_DIR\custom.scss" "$QUARTZ_DIR\quartz\styles\custom.scss" -Force

# Apply patches
$patchesDir = "$VOX_DIR\patches"
$patches = Get-ChildItem "$patchesDir\*.patch" -ErrorAction SilentlyContinue
if ($patches) {
    Write-Host "[vox] Applying patches..."
    foreach ($p in $patches) {
        git -C $QUARTZ_DIR apply --reverse --ignore-whitespace $p.FullName 2>$null
    }
    foreach ($p in $patches) {
        git -C $QUARTZ_DIR apply --ignore-whitespace $p.FullName
        Write-Host "  applied: $($p.Name)"
    }
}

# Serve
Set-Location $QUARTZ_DIR
$env:CONTENT_DIR = $CONTENT_DIR
Write-Host "[vox] Serving on http://localhost:8085 ..."
npx quartz build --serve --port 8085
