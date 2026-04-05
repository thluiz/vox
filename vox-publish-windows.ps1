# vox-publish-windows.ps1 — equivalente ao vox-publish.sh mas corre no Windows
param(
    [switch]$SkipPull,
    [switch]$SkipBuild,
    [switch]$ForceFullSync
)

$ErrorActionPreference = "Stop"

# Logging — redirige todo o output para ficheiro com timestamp
$VOX_DIR      = "E:\vox"
$logDir = Join-Path $VOX_DIR "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("vox-publish-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
Start-Transcript -Path $logFile -Force | Out-Null
try {
$QUARTZ_DIR   = "E:\quartz"
$CONTENT_DIR  = "E:\vox-content"
$SCRIPTS_DIR  = $VOX_DIR

# Garantir fnm + node no PATH (scheduled tasks não carregam o perfil do utilizador)
$fnmExe = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\Schniz.fnm_Microsoft.Winget.Source_8wekyb3d8bbwe\fnm.exe"
if (Test-Path $fnmExe) {
    & $fnmExe env --shell powershell | Out-String | Invoke-Expression
    Write-Host "[vox] Node: $(node --version) via fnm"
}

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
Set-Location $QUARTZ_DIR
$env:CONTENT_DIR = $CONTENT_DIR

if ($SkipBuild) {
    Write-Host "[vox] Build Quartz ignorado (-SkipBuild)."
} else {
    Write-Host "[vox] Build Quartz..."

    # Atualizar home page
    python "$SCRIPTS_DIR\update-vox-home.py"

    # Commitar index.md se alterado
    $diff = git -C $CONTENT_DIR diff --quiet index.md 2>$null
    if ($LASTEXITCODE -ne 0) {
        git -C $CONTENT_DIR add index.md
        git -C $CONTENT_DIR commit -m "chore: update index.md (top tags + recent posts)" --quiet
        git -C $CONTENT_DIR push --quiet
    }

    npx quartz build --concurrency 24
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
}

# Deploy S3 + CloudFront — diff baseado em git + manifest
$publicDir      = "$QUARTZ_DIR\public"
$manifestFile   = "$VOX_DIR\public-manifest.json"
$lastCommitFile = "$VOX_DIR\last-published-commit.txt"
$bucket         = "s3://hermes-vox-br"
$cacheCtrl      = "public, max-age=3600"

$prevManifest  = @{}
if (Test-Path $manifestFile) {
    $prevManifest = Get-Content $manifestFile -Raw | ConvertFrom-Json -AsHashtable
}

$currentCommit = (git -C $CONTENT_DIR rev-parse HEAD).Trim()
$lastCommit    = if (Test-Path $lastCommitFile) { (Get-Content $lastCommitFile -Raw).Trim() } else { $null }

# Derivar conjunto de arquivos HTML a verificar a partir do git diff
function Get-HtmlPathsToCheck($contentDir, $publicDir, $lastCommit, $currentCommit) {
    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Sempre verificar: home, 404, sitemap
    @('index.html', '404.html', 'sitemap.xml') | ForEach-Object {
        if (Test-Path (Join-Path $publicDir $_)) { $paths.Add($_) | Out-Null }
    }

    if (-not $lastCommit -or $lastCommit -eq $currentCommit) { return $paths }

    # Arquivos de conteúdo alterados desde o último publish
    $changed = git -C $contentDir diff --name-only $lastCommit $currentCommit 2>$null |
               Where-Object { $_ -match '\.(md|json)$' }

    foreach ($f in $changed) {
        # Episódio: 2025/02/W06/slug.md → public\2025\02\W06\slug.html
        $noExt   = [System.IO.Path]::GetFileNameWithoutExtension($f)
        $dir     = [System.IO.Path]::GetDirectoryName($f) -replace '/', '\'
        $htmlRel = if ($dir) { "$dir\$noExt.html" } else { "$noExt.html" }
        $paths.Add($htmlRel) | Out-Null

        # og-image PNG gerado pelo Quartz para cada episódio
        $ogRel = if ($dir) { "$dir\$noExt-og-image.png" } else { "$noExt-og-image.png" }
        if (Test-Path (Join-Path $publicDir $ogRel)) { $paths.Add($ogRel) | Out-Null }

        # Folder indexes de cada nível pai: ano, mês, semana (deduplicados pelo HashSet)
        $parts = ($dir -split '\\') | Where-Object { $_ }
        for ($i = 1; $i -le $parts.Length; $i++) {
            $paths.Add(($parts[0..($i-1)] -join '\') + '\index.html') | Out-Null
        }

        # Tags do episódio: ler do JSON (se existir) ou do MD (frontmatter)
        $jsonFile = Join-Path $contentDir ($dir + '\' + $noExt + '.json')
        $mdFile   = Join-Path $contentDir $f
        $tags = @()
        if (Test-Path $jsonFile) {
            try {
                $jdata = Get-Content $jsonFile -Raw | ConvertFrom-Json
                if ($jdata.frontmatter.tags) { $tags = @($jdata.frontmatter.tags) }
                elseif ($jdata.tags)         { $tags = @($jdata.tags) }
            } catch {}
        } elseif (Test-Path $mdFile) {
            # Extrair tags do frontmatter YAML simples: "tags: [a, b]" ou "- tag"
            $inFront = $false; $inTags = $false
            foreach ($line in (Get-Content $mdFile)) {
                if ($line -eq '---') { if (-not $inFront) { $inFront = $true } else { break } ; continue }
                if (-not $inFront) { continue }
                if ($line -match '^tags\s*:\s*\[(.+)\]') {
                    $tags = $Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") }
                    $inTags = $false; break
                }
                if ($line -match '^tags\s*:') { $inTags = $true; continue }
                if ($inTags -and $line -match '^\s*-\s*(.+)') { $tags += $Matches[1].Trim() }
                elseif ($inTags) { $inTags = $false }
            }
        }
        foreach ($tag in $tags) {
            # tag kebab: lowercase, spaces→hyphens
            $slug = $tag.ToLower() -replace '\s+', '-'
            $tagHtml = "tags\$slug.html"
            if (Test-Path (Join-Path $publicDir $tagHtml)) { $paths.Add($tagHtml) | Out-Null }
        }
    }
    return $paths
}

$pathsToCheck = Get-HtmlPathsToCheck $CONTENT_DIR $publicDir $lastCommit $currentCommit
$isFullScan   = $ForceFullSync -or (-not $lastCommit)

if ($isFullScan) {
    Write-Host "[vox] $(if ($ForceFullSync) { 'ForceFullSync' } else { 'Primeiro publish' }) — scan completo..."
    $filesToHash = Get-ChildItem $publicDir -Recurse -File | Where-Object { $_.Name -ne '.DS_Store' }
} elseif ($lastCommit -eq $currentCommit) {
    Write-Host "[vox] Sem novos commits em vox-content — nada a publicar."
    $filesToHash = @()
} else {
    $episodeCount = (git -C $CONTENT_DIR diff --name-only $lastCommit $currentCommit | Where-Object { $_ -match '\.(md|json)$' } | Measure-Object).Count
    Write-Host "[vox] $($pathsToCheck.Count) arquivos a verificar (git diff: $episodeCount episódios)..."
    $filesToHash = $pathsToCheck | ForEach-Object {
        $full = Join-Path $publicDir $_
        if (Test-Path $full) { Get-Item $full }
    } | Where-Object { $_ }
}

$results = $filesToHash | ForEach-Object -Parallel {
    $rel  = $_.FullName.Substring($using:publicDir.Length + 1)
    $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    [PSCustomObject]@{ Rel = $rel; Hash = $hash }
} -ThrottleLimit 24

$newManifest = $prevManifest.Clone()
$toUpload    = [System.Collections.Generic.List[string]]::new()

foreach ($r in $results) {
    $newManifest[$r.Rel] = $r.Hash
    if ($prevManifest[$r.Rel] -ne $r.Hash) { $toUpload.Add($r.Rel) }
}

# Detetar deleções: só em full scan (incremental não tem visão completa do public/)
$toDelete = [System.Collections.Generic.List[string]]::new()
if ($isFullScan) {
    foreach ($key in $prevManifest.Keys) {
        if (-not (Test-Path (Join-Path $publicDir $key))) {
            $toDelete.Add($key)
            $newManifest.Remove($key) | Out-Null
        }
    }
}

Write-Host "[vox] Upload: $($toUpload.Count) | Delete: $($toDelete.Count)"

if ($toUpload.Count -eq 0 -and $toDelete.Count -eq 0) {
    Write-Host "[vox] Sem alterações — skip S3"
} else {
    if ($isFullScan) {
        # Full sync: aws s3 sync paraleliza internamente, muito mais rápido
        Write-Host "[vox] Full sync via s3 sync..."
        & $aws s3 sync $publicDir $bucket `
            --cache-control $cacheCtrl `
            --delete
        if ($LASTEXITCODE -ne 0) { throw "[vox] Falha no s3 sync" }
    } else {
        # Incremental: só os arquivos alterados — paralelo
        $awsExe = $aws
        $uploadErrors = $toUpload | ForEach-Object -Parallel {
            $s3Key = $_.Replace('\', '/')
            $result = & $using:awsExe s3 cp (Join-Path $using:publicDir $_) "$using:bucket/$s3Key" `
                --cache-control $using:cacheCtrl 2>&1
            if ($LASTEXITCODE -ne 0) { "FAIL: $s3Key — $result" }
        } -ThrottleLimit 16
        if ($uploadErrors) { throw "[vox] Falhas no upload:`n$($uploadErrors -join "`n")" }

        foreach ($rel in $toDelete) {
            & $aws s3 rm "$bucket/$($rel.Replace('\','/'))" | Out-Null
        }
    }

    Write-Host "[vox] Invalidando cache CloudFront..."
    & $aws cloudfront create-invalidation `
        --distribution-id $env:AWS_CF_DISTRIBUTION_ID `
        --paths "/*" | Out-Null
}

# Gravar manifest e commit atual
$newManifest | ConvertTo-Json -Compress | Set-Content $manifestFile -Encoding UTF8
$currentCommit | Set-Content $lastCommitFile -Encoding UTF8

# Push vox-content
Write-Host "[vox] Pushing vox-content..."
git -C $CONTENT_DIR push

Write-Host "[vox] Publicado com sucesso!"

# Notificação GossipGate
$gossipKey = (Get-Content 'C:\Users\conta\.gossipgate\api-key' -Raw).Trim()
$gossipUrl = 'http://localhost:8080/api/gossip-gate/send'

if ($toUpload.Count -eq 0 -and $toDelete.Count -eq 0) {
    # sem alterações — não notifica
} elseif ($isFullScan) {
    $msg = "🌐 <b>Vox publicado</b> — full sync: $($toUpload.Count) arquivos enviados ao S3"
    Invoke-RestMethod -Uri $gossipUrl -Method Post `
        -Headers @{ 'X-Api-Key' = $gossipKey; 'Content-Type' = 'application/json' } `
        -Body ([System.Text.Encoding]::UTF8.GetBytes((@{ message = $msg; parse_mode = 'HTML' } | ConvertTo-Json -Compress))) | Out-Null
} else {
    # Filtrar só episódios: paths com padrão {year}\{month}\W{week}\{slug}.html
    $episodes = $toUpload | Where-Object { $_ -match '^\d{4}\\' -and $_ -match '\.html$' -and $_ -notmatch 'index\.html$' -and $_ -match '\\W\d+\\' }
    if ($episodes) {
        $lines = $episodes | ForEach-Object {
            $slug = [System.IO.Path]::GetFileNameWithoutExtension($_)
            $dir  = [System.IO.Path]::GetDirectoryName($_) -replace '\\', '/'
            "• <a href=""https://vox.thluiz.com/$dir/$slug"">$slug</a>"
        }
        $msg = "✅ <b>Vox publicado</b> — $($episodes.Count) episódio$(if($episodes.Count -gt 1){'s'})`n" + ($lines -join "`n")
    } else {
        $msg = "✅ <b>Vox publicado</b> — $($toUpload.Count) arquivo$(if($toUpload.Count -gt 1){'s'}) atualizados"
    }
    Invoke-RestMethod -Uri $gossipUrl -Method Post `
        -Headers @{ 'X-Api-Key' = $gossipKey; 'Content-Type' = 'application/json' } `
        -Body ([System.Text.Encoding]::UTF8.GetBytes((@{ message = $msg; parse_mode = 'HTML' } | ConvertTo-Json -Compress))) | Out-Null
}

} catch {
    Write-Error "FATAL: $_"
    Write-Error $_.ScriptStackTrace
    throw
} finally {
    Stop-Transcript | Out-Null
    # Limpar logs com mais de 7 dias
    Get-ChildItem (Join-Path $VOX_DIR "logs") -Filter "vox-publish-*.log" |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
