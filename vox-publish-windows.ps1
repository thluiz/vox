# vox-publish-windows.ps1 — Hugo build + deploy S3 por diferença (manifest SHA256)
param(
    [switch]$SkipPull,
    [switch]$SkipBuild,
    # Ignora o gate do -GateOnNewEpisodes. Todo publish já hasheia o public/
    # inteiro e sobe só o que diferir; não existe mais modo incremental.
    [switch]$ForceFullSync,
    # Escape hatch para drift entre S3 e manifest (ex: mexeram no bucket à mão):
    # usa 'aws s3 sync --delete', que reenvia o site inteiro (Hugo reescreve o
    # mtime de todo o public/). Implica -ForceFullSync.
    [switch]$S3Sync,
    # Usado pelo scheduler horário: sai antes do build se nem vox-content nem a
    # apresentação mudaram desde o último publish. Manuais (sem a flag) sempre buildam.
    [switch]$GateOnNewEpisodes
)

$ErrorActionPreference = "Stop"
if ($S3Sync) { $ForceFullSync = $true }

$VOX_HUGO     = "E:\vox"
$HEXTRA_DIR   = "E:\hextra"
$CONTENT_DIR  = "E:\vox-content"

# Logging
$logDir = Join-Path $VOX_HUGO "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("vox-publish-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
Start-Transcript -Path $logFile -Force | Out-Null
try {

# Carregar .env (AWS credentials)
$envFile = Join-Path $VOX_HUGO ".env"
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
    throw "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY nao definidos — verifique .env"
}
if (-not $env:AWS_CF_DISTRIBUTION_ID) {
    throw "AWS_CF_DISTRIBUTION_ID nao definido — verifique .env"
}

$env:AWS_DEFAULT_REGION = if ($env:AWS_REGION) { $env:AWS_REGION } else { "sa-east-1" }
$aws = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'

# Pull robusto: resolve untracked-collisions e nunca falha silenciosamente.
# Causa histórica de "site parado sem ninguém perceber": um .json untracked no
# working tree colidia com o mesmo path vindo do remoto; `git pull --ff-only`
# abortava, e como PS não captura exit code de exe nativo via ErrorAction, o
# script seguia e reportava sucesso falso. Esta função torna o pull à prova disso.
function Invoke-RobustPull {
    param([string]$RepoDir, [string]$Label)

    $branch = (git -C $RepoDir rev-parse --abbrev-ref HEAD).Trim()
    git -C $RepoDir fetch origin --quiet
    if ($LASTEXITCODE -ne 0) { throw "[vox] git fetch falhou em $Label (exit $LASTEXITCODE)" }

    $remoteRef = "origin/$branch"
    $local  = (git -C $RepoDir rev-parse HEAD).Trim()
    $remote = (git -C $RepoDir rev-parse $remoteRef).Trim()
    if ($local -eq $remote) { Write-Host "[vox]   $Label já atualizado."; return }

    # Resolver arquivos untracked que colidem com o que vem do remoto.
    # Remove só os byte-idênticos (sem perda); aborta se algum diferir.
    $untracked = git -C $RepoDir ls-files --others --exclude-standard
    foreach ($f in $untracked) {
        if (-not $f) { continue }
        git -C $RepoDir cat-file -e "${remoteRef}:${f}" 2>$null   # path existe no remoto?
        if ($LASTEXITCODE -ne 0) { continue }                      # não colide, ignora

        $localBlob  = (git -C $RepoDir hash-object "$f").Trim()
        $remoteBlob = (git -C $RepoDir rev-parse "${remoteRef}:${f}").Trim()
        if ($localBlob -eq $remoteBlob) {
            Write-Host "[vox]   untracked idêntico ao remoto — removendo: $f"
            Remove-Item (Join-Path $RepoDir $f) -Force
        } else {
            throw "[vox] CONFLITO em ${Label}: untracked '$f' difere da versão do remoto. Resolver manualmente antes do próximo publish."
        }
    }

    git -C $RepoDir merge --ff-only $remoteRef
    if ($LASTEXITCODE -ne 0) {
        throw "[vox] git merge --ff-only falhou em $Label (exit $LASTEXITCODE) — histórico provavelmente divergiu."
    }

    $now = (git -C $RepoDir rev-parse HEAD).Trim()
    if ($now -ne $remote) {
        throw "[vox] $Label não chegou ao remoto após pull (HEAD=$now, esperado=$remote)"
    }
    Write-Host "[vox]   ${Label}: $($local.Substring(0,8)) -> $($now.Substring(0,8))"
}

# Pull
if (-not $SkipPull) {
    Write-Host "[vox] Atualizando vox-content..."
    Invoke-RobustPull -RepoDir $CONTENT_DIR -Label "vox-content"
    Write-Host "[vox] Atualizando vox-hugo..."
    git -C $VOX_HUGO pull --ff-only 2>$null   # E:\vox pode ter edits locais; ff best-effort
}

# Fingerprint da apresentação: tudo que, ao mudar, reescreve o HTML de todas as
# páginas sem aparecer no git diff do vox-content — layouts, CSS, config, tema,
# versão do Hugo. Inclui edições não commitadas (o build usa o working tree).
function Get-PresentationFingerprint {
    $items = [System.Collections.Generic.List[string]]::new()
    $files = @(Get-Item "$VOX_HUGO\hugo.toml")
    foreach ($d in @('layouts', 'assets', 'static', 'content-home', 'patches')) {
        $full = Join-Path $VOX_HUGO $d
        if (Test-Path $full) { $files += Get-ChildItem $full -Recurse -File }
    }
    foreach ($f in ($files | Sort-Object FullName)) {
        $items.Add("$($f.FullName.Substring($VOX_HUGO.Length + 1))=$((Get-FileHash $f.FullName -Algorithm SHA256).Hash)")
    }
    $items.Add("hextra=$((git -C $HEXTRA_DIR rev-parse HEAD).Trim())")
    $items.Add("hugo=$((hugo version) -replace ' BuildDate=.*$', '')")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($items -join "`n"))
    return [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')
}

$presentationFile = "$VOX_HUGO\last-published-presentation.txt"
$presentationNow  = Get-PresentationFingerprint
$presentationLast = if (Test-Path $presentationFile) { (Get-Content $presentationFile -Raw).Trim() } else { $null }

# Gate do scheduler horário (-GateOnNewEpisodes): só gasta build Hugo + deploy se
# vox-content avançou desde o último publish OU a apresentação mudou (layout,
# CSS, config, tema, versão do Hugo). Execuções manuais NÃO passam esta flag,
# então sempre buildam.
if ($GateOnNewEpisodes -and -not $ForceFullSync) {
    $gateLastFile = "$VOX_HUGO\last-published-commit.txt"
    $gateCurrent  = (git -C $CONTENT_DIR rev-parse HEAD).Trim()
    $gateLast     = if (Test-Path $gateLastFile) { (Get-Content $gateLastFile -Raw).Trim() } else { $null }
    if ($gateLast -and $gateLast -eq $gateCurrent -and $presentationNow -eq $presentationLast) {
        Write-Host "[vox] Sem episódios novos em vox-content ($($gateCurrent.Substring(0,8))) nem mudança de apresentação — nada a publicar. Saindo."
        return
    }
    Write-Host "[vox] Mudanças detectadas (conteúdo e/ou apresentação) — prosseguindo com publish."
}

# Apply patches to Hextra
$patchesDir = "$VOX_HUGO\patches"
$patches = Get-ChildItem "$patchesDir\*.patch" -ErrorAction SilentlyContinue
if ($patches) {
    Write-Host "[vox] Applying Hextra patches..."
    foreach ($p in $patches) {
        git -C $HEXTRA_DIR apply --reverse --ignore-whitespace $p.FullName 2>$null
    }
    foreach ($p in $patches) {
        $check = git -C $HEXTRA_DIR apply --ignore-whitespace --check $p.FullName 2>&1
        if ($LASTEXITCODE -eq 0) {
            git -C $HEXTRA_DIR apply --ignore-whitespace $p.FullName
            Write-Host "  applied: $($p.Name)"
        } else {
            Write-Error "  FAILED: $($p.Name) — patch does not apply cleanly"
            exit 1
        }
    }
}

# Build
if ($SkipBuild) {
    Write-Host "[vox] Build Hugo ignorado (-SkipBuild)."
} else {
    Write-Host "[vox] Build Hugo..."
    Set-Location $VOX_HUGO
    # --cleanDestinationDir: sem ele o Hugo nunca apaga do public/ o que deixou
    # de gerar (tags renomeadas, CSS/JS com hash antigo) e o detector de
    # deleções abaixo nunca as vê — ficavam no S3 para sempre.
    hugo --logLevel warn --cleanDestinationDir
    if ($LASTEXITCODE -ne 0) {
        throw "[vox] Build falhou (exit $LASTEXITCODE) — abortando deploy"
    }

    # Reverter patches
    if ($patches) {
        Write-Host "[vox] Reverting Hextra patches..."
        foreach ($p in $patches) {
            git -C $HEXTRA_DIR apply --reverse --ignore-whitespace $p.FullName 2>$null
        }
    }
}

# Deploy S3 + CloudFront — diff por manifest SHA256 do public/ inteiro
#
# Sempre hasheia o public/ todo (local, paralelo, ~1-2 min para ~58k arquivos).
# Derivar as páginas afetadas a partir do git diff (versão anterior) deixava
# para trás tudo que muda indiretamente quando entra um episódio — paginação,
# listagens, páginas vizinhas — e esses ~5k arquivos só subiam no próximo
# -ForceFullSync. Também é o único jeito seguro de detectar deleções.
$publicDir      = "$VOX_HUGO\public"
$manifestFile   = "$VOX_HUGO\public-manifest.json"
$lastCommitFile = "$VOX_HUGO\last-published-commit.txt"
$bucket         = "s3://hermes-vox-br"
$cacheCtrl      = "public, max-age=3600"

$prevManifest  = @{}
if (Test-Path $manifestFile) {
    $prevManifest = Get-Content $manifestFile -Raw | ConvertFrom-Json -AsHashtable
}

$currentCommit = (git -C $CONTENT_DIR rev-parse HEAD).Trim()
$prevCommit    = if (Test-Path $lastCommitFile) { (Get-Content $lastCommitFile -Raw).Trim() } else { $null }

Write-Host "[vox] Hash do public/ inteiro..."
$filesToHash = Get-ChildItem $publicDir -Recurse -File | Where-Object { $_.Name -ne '.DS_Store' }
$results = $filesToHash | ForEach-Object -Parallel {
    $rel  = $_.FullName.Substring($using:publicDir.Length + 1)
    $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    [PSCustomObject]@{ Rel = $rel; Hash = $hash }
} -ThrottleLimit 24

$newManifest = @{}
$toUpload    = [System.Collections.Generic.List[string]]::new()
foreach ($r in $results) {
    $newManifest[$r.Rel] = $r.Hash
    if ($prevManifest[$r.Rel] -ne $r.Hash) { $toUpload.Add($r.Rel) }
}

# Deleções: estava no manifest anterior e não existe mais no public/
# (o build usa --cleanDestinationDir, então o public/ reflete só o que o Hugo gera)
$toDelete = [System.Collections.Generic.List[string]]::new()
foreach ($key in $prevManifest.Keys) {
    if (-not $newManifest.ContainsKey($key)) { $toDelete.Add($key) }
}

Write-Host "[vox] Upload: $($toUpload.Count) | Delete: $($toDelete.Count)"

if ($toUpload.Count -eq 0 -and $toDelete.Count -eq 0) {
    Write-Host "[vox] Sem alterações — skip S3"
} else {
    # Subir sempre por 's3 cp' do que diferiu no manifest SHA256, nunca 's3 sync':
    # o sync compara tamanho+mtime e o Hugo reescreve o mtime de TODO o public/
    # a cada build — o sync reenviava ~4.5 GiB mesmo com meia dúzia de páginas
    # alteradas. 's3 sync' só via -S3Sync (drift entre S3 e manifest).
    if ($S3Sync) {
        Write-Host "[vox] -S3Sync — s3 sync --delete do public/ inteiro..."
        & $aws s3 sync $publicDir $bucket `
            --cache-control $cacheCtrl `
            --delete
        if ($LASTEXITCODE -ne 0) { throw "[vox] Falha no s3 sync" }
    } else {
        # Um processo 'aws' por arquivo custava ~0.25s de startup cada (4980
        # arquivos = ~20 min). Em vez disso: espelha só os alterados numa pasta
        # de staging (hard links, mesmo volume — sem copiar dados) e sobe tudo
        # num único 's3 cp --recursive' com concorrência alta.
        if ($toUpload.Count -gt 0) {
            Write-Host "[vox] Upload de $($toUpload.Count) arquivo(s)..."
            $staging = Join-Path $VOX_HUGO ".upload-staging"
            if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
            if (-not ('Vox.Native' -as [type])) {
                Add-Type -Namespace Vox -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CreateHardLink(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);
'@
            }
            foreach ($rel in $toUpload) {
                $src = Join-Path $publicDir $rel
                $dst = Join-Path $staging $rel
                [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dst))
                if (-not [Vox.Native]::CreateHardLink($dst, $src, [IntPtr]::Zero)) {
                    Copy-Item -LiteralPath $src -Destination $dst
                }
            }

            # Concorrência do CLI via config temporário (credenciais vêm do .env)
            $prevCfg = $env:AWS_CONFIG_FILE
            $awsCfg  = Join-Path $env:TEMP "vox-publish-aws-config"
            "[default]`ns3 =`n    max_concurrent_requests = 64`n    max_queue_size = 10000`n" |
                Set-Content $awsCfg -Encoding ascii
            $env:AWS_CONFIG_FILE = $awsCfg
            $env:PYTHONUTF8 = '1'   # paths com acento (tags/ética) no output do CLI
            try {
                & $aws s3 cp $staging $bucket --recursive `
                    --cache-control $cacheCtrl --only-show-errors
                $cpExit = $LASTEXITCODE
            } finally {
                $env:AWS_CONFIG_FILE = $prevCfg
                Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($cpExit -ne 0) { throw "[vox] Falha no upload (aws s3 cp exit $cpExit)" }
        }

        # Deleções em lote (delete-objects aceita até 1000 chaves por chamada)
        if ($toDelete.Count -gt 0) {
            Write-Host "[vox] Removendo $($toDelete.Count) arquivo(s) do S3..."
            $bucketName = $bucket -replace '^s3://', ''
            $batchFile  = Join-Path $env:TEMP "vox-publish-delete.json"
            for ($i = 0; $i -lt $toDelete.Count; $i += 1000) {
                $chunk = $toDelete[$i..([Math]::Min($i + 999, $toDelete.Count - 1))]
                $payload = @{
                    Objects = @($chunk | ForEach-Object { @{ Key = $_.Replace('\', '/') } })
                    Quiet   = $true
                } | ConvertTo-Json -Depth 4 -Compress
                [System.IO.File]::WriteAllText($batchFile, $payload, [System.Text.UTF8Encoding]::new($false))
                $resp = & $aws s3api delete-objects --bucket $bucketName --delete "file://$batchFile" --output json
                if ($LASTEXITCODE -ne 0) { throw "[vox] Falha no delete-objects (exit $LASTEXITCODE)" }
                $errs = ($resp | Out-String | ConvertFrom-Json -ErrorAction SilentlyContinue).Errors
                if ($errs) { throw "[vox] delete-objects com erros:`n$(($errs | ForEach-Object { "$($_.Key): $($_.Message)" }) -join "`n")" }
            }
            Remove-Item $batchFile -Force -ErrorAction SilentlyContinue
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
$presentationNow | Set-Content $presentationFile -Encoding UTF8

# Push vox-content (se houver alterações)
$contentStatus = git -C $CONTENT_DIR status --porcelain 2>$null
if ($contentStatus) {
    Write-Host "[vox] Pushing vox-content..."
    git -C $CONTENT_DIR push
}

Write-Host "[vox] Publicado com sucesso!"

# Notificação GossipGate
$gossipKey = (Get-Content 'C:\Users\conta\.gossipgate\api-key' -Raw).Trim()
$gossipUrl = 'http://localhost:8080/api/gossip-gate/send'

if ($toUpload.Count -eq 0 -and $toDelete.Count -eq 0) {
    # sem alterações — não notifica
} else {
    # Episódios novos vêm do git diff (arquivos .md adicionados), não do upload:
    # com o hash do public/ inteiro, o upload inclui páginas de episódios antigos
    # que mudaram só indiretamente (navegação, listagens).
    $episodes = @()
    if ($prevCommit -and $prevCommit -ne $currentCommit) {
        $episodes = @(git -C $CONTENT_DIR diff --name-only --diff-filter=A $prevCommit $currentCommit |
            Where-Object { $_ -match '^\d{4}/.*/[wW]\d+/[^/]+\.md$' })
    }
    if ($episodes) {
        $lines = $episodes | ForEach-Object {
            $dir  = $_ -replace '\.md$', ''
            $slug = ($dir -split '/')[-1]
            "• <a href=""https://vox.thluiz.com/$dir/"">$slug</a>"
        }
        $msg = "✅ <b>Vox publicado (Hugo)</b> — $($episodes.Count) episódio$(if($episodes.Count -gt 1){'s'})`n" + ($lines -join "`n")
    } else {
        $msg = "✅ <b>Vox publicado (Hugo)</b> — $($toUpload.Count) arquivo$(if($toUpload.Count -gt 1){'s'}) atualizados"
    }
    Invoke-RestMethod -Uri $gossipUrl -Method Post `
        -Headers @{ 'X-Api-Key' = $gossipKey; 'Content-Type' = 'application/json' } `
        -Body ([System.Text.Encoding]::UTF8.GetBytes((@{ message = $msg; parse_mode = 'HTML' } | ConvertTo-Json -Compress))) | Out-Null
}

} catch {
    Write-Error "FATAL: $_"
    Write-Error $_.ScriptStackTrace
    # Alerta proativo — falha de publish não pode passar despercebida por dias
    try {
        $gk = (Get-Content 'C:\Users\conta\.gossipgate\api-key' -Raw).Trim()
        $fmsg = "🛑 <b>Vox publish FALHOU</b>`n<code>$($_.ToString())</code>"
        Invoke-RestMethod -Uri 'http://localhost:8080/api/gossip-gate/send' -Method Post `
            -Headers @{ 'X-Api-Key' = $gk; 'Content-Type' = 'application/json' } `
            -Body ([System.Text.Encoding]::UTF8.GetBytes((@{ message = $fmsg; parse_mode = 'HTML' } | ConvertTo-Json -Compress))) | Out-Null
    } catch { Write-Error "[vox] (falha ao notificar GossipGate: $_)" }
    throw
} finally {
    Stop-Transcript | Out-Null
    Get-ChildItem (Join-Path $VOX_HUGO "logs") -Filter "vox-publish-*.log" |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
