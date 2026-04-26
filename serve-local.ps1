$ErrorActionPreference = "Stop"

$HEXTRA_DIR = "E:\hextra"
$VOX_HUGO   = "E:\vox"
$PATCHES_DIR = "$VOX_HUGO\patches"

# --- Apply patches to Hextra ---
$patches = Get-ChildItem "$PATCHES_DIR\*.patch" -ErrorAction SilentlyContinue
if ($patches) {
    Write-Host "[vox-hugo] Applying patches to Hextra..."
    foreach ($p in $patches) {
        git -C $HEXTRA_DIR apply --reverse --ignore-whitespace $p.FullName 2>$null
    }
    foreach ($p in $patches) {
        git -C $HEXTRA_DIR apply --ignore-whitespace $p.FullName
        Write-Host "  applied: $($p.Name)"
    }
}

# --- Serve ---
Write-Host "[vox-hugo] Serving on http://localhost:8085 ..."
try {
    hugo server --port 8085 --source $VOX_HUGO --logLevel info
}
finally {
    # --- Revert patches on exit ---
    if ($patches) {
        Write-Host "`n[vox-hugo] Reverting patches..."
        foreach ($p in $patches) {
            git -C $HEXTRA_DIR apply --reverse --ignore-whitespace $p.FullName 2>$null
        }
    }
}
