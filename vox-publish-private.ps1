#requires -Version 7
# vox-publish-private.ps1 — publica o Vox PRIVADO (vox.thluiz.com/privado/<guid>/).
#
#   1. atualiza E:\vox-private-content (pull ff-only)
#   2. Hugo build com hugo.private.toml (baseURL com o guid) em E:\vox\public-private
#   3. s3 sync para s3://hermes-vox-private-br/privado/<guid>/ (--delete só dentro do prefixo)
#   4. portal /privado/index.html (atrás de senha HTTP) com o link do site
#   5. invalidação do CloudFront e conferência de que o site responde
#
# Credenciais: ~/.secrets/vox-private.json -> "aws" (usuário vox-private-deploy, só o prefixo privado),
# ou, sem a chave, -AwsProfile (ex.: scholion-admin) para execução manual. O guid e a senha vêm do
# mesmo arquivo; nada disso é impresso nem commitado.
#
#   pwsh -NoProfile -File vox-publish-private.ps1                    # manual: sempre builda
#   pwsh -NoProfile -File vox-publish-private.ps1 -GateOnNewEpisodes # agendador: só se algo mudou
param(
    [switch]$SkipPull,
    [switch]$GateOnNewEpisodes,
    [switch]$Force,
    [string]$AwsProfile,
    [string]$ContentDir = 'E:\vox-private-content',
    [string]$OutDir = 'E:\vox\public-private'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:PYTHONUTF8 = '1'

$VOX_HUGO   = 'E:\vox'
$HEXTRA_DIR = 'E:\hextra'
$BUCKET     = 'hermes-vox-private-br'
$S3_REGION  = 'sa-east-1'
$DIST_ID    = 'EBJV9APC86R77'
$aws        = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'

$logDir = Join-Path $VOX_HUGO 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("vox-publish-private-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
Start-Transcript -Path $logFile -Force | Out-Null

function Send-Gossip([string]$html) {
    try {
        $key = (Get-Content 'C:\Users\conta\.gossipgate\api-key' -Raw).Trim()
        Invoke-RestMethod -Uri 'http://localhost:8080/api/gossip-gate/send' -Method Post `
            -Headers @{ 'X-Api-Key' = $key; 'Content-Type' = 'application/json' } `
            -Body ([Text.Encoding]::UTF8.GetBytes((@{ message = $html; parse_mode = 'HTML' } | ConvertTo-Json -Compress))) | Out-Null
    } catch { Write-Host "[vox-private] aviso: GossipGate indisponível ($($_.Exception.Message))" }
}

# O build do Hugo público e o privado compartilham a árvore E:\vox (layouts, resources/, patches no
# Hextra): nunca em paralelo. Mesmo mutex do público, mas aqui ESPERA em vez de sair.
$lock = [System.Threading.Mutex]::new($false, 'Global\VoxPublish')
$hasLock = $false
try { $hasLock = $lock.WaitOne([TimeSpan]::FromMinutes(25)) } catch [System.Threading.AbandonedMutexException] { $hasLock = $true }
if (-not $hasLock) {
    Write-Host '[vox-private] publish do Vox público ainda rodando após 25 min — saindo sem fazer nada.'
    Stop-Transcript | Out-Null
    exit 0
}

try {
    # --- credenciais do site (guid + senha) e da AWS
    $secretsFile = Join-Path $HOME '.secrets\vox-private.json'
    if (-not (Test-Path $secretsFile)) { throw "faltam as credenciais do Vox privado: $secretsFile (rode infra/private/03-seed.ps1)" }
    $secrets = Get-Content -Raw -Encoding utf8 $secretsFile | ConvertFrom-Json
    $guid = $secrets.guid
    if ($guid -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'guid inválido no arquivo de segredos' }

    $awsArgs = @('--region', $S3_REGION)
    if ($AwsProfile) {
        $awsArgs += @('--profile', $AwsProfile)
    } elseif ($secrets.aws -and $secrets.aws.accessKeyId) {
        $env:AWS_ACCESS_KEY_ID = $secrets.aws.accessKeyId
        $env:AWS_SECRET_ACCESS_KEY = $secrets.aws.secretAccessKey
    } else {
        throw 'sem credencial AWS: crie o usuário (infra/private/04-iam.ps1) ou passe -AwsProfile'
    }

    # --- pull do repositório privado (nunca perde o que tem local: só fast-forward)
    if (-not $SkipPull) {
        Write-Host '[vox-private] Atualizando vox-private-content...'
        $branch = (git -C $ContentDir rev-parse --abbrev-ref HEAD).Trim()
        git -C $ContentDir fetch origin --quiet
        if ($LASTEXITCODE -ne 0) { throw "git fetch falhou (exit $LASTEXITCODE)" }
        $local = (git -C $ContentDir rev-parse HEAD).Trim()
        $remote = (git -C $ContentDir rev-parse "origin/$branch").Trim()
        if ($local -ne $remote) {
            git -C $ContentDir merge --ff-only "origin/$branch"
            if ($LASTEXITCODE -ne 0) { throw "git merge --ff-only falhou (exit $LASTEXITCODE) — histórico divergiu?" }
        }
    }
    $currentCommit = (git -C $ContentDir rev-parse HEAD).Trim()

    # --- fingerprint da apresentação: o que, ao mudar, reescreve todas as páginas
    $files = @(Get-Item "$VOX_HUGO\hugo.private.toml")
    foreach ($d in @('layouts', 'assets', 'static', 'content-home-private')) {
        $full = Join-Path $VOX_HUGO $d
        if (Test-Path $full) { $files += Get-ChildItem $full -Recurse -File }
    }
    $items = foreach ($f in ($files | Sort-Object FullName)) {
        "$($f.FullName.Substring($VOX_HUGO.Length + 1))=$((Get-FileHash $f.FullName -Algorithm SHA256).Hash)"
    }
    $items += "hextra=$((git -C $HEXTRA_DIR rev-parse HEAD).Trim())"
    $items += "hugo=$((hugo version) -replace ' BuildDate=.*$', '')"
    $presentationNow = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($items -join "`n")))).Replace('-', '')

    $lastCommitFile = Join-Path $VOX_HUGO 'last-published-private-commit.txt'
    $lastPresFile = Join-Path $VOX_HUGO 'last-published-private-presentation.txt'
    $lastCommit = if (Test-Path $lastCommitFile) { (Get-Content $lastCommitFile -Raw).Trim() } else { $null }
    $lastPres = if (Test-Path $lastPresFile) { (Get-Content $lastPresFile -Raw).Trim() } else { $null }

    if ($GateOnNewEpisodes -and -not $Force -and $lastCommit -eq $currentCommit -and $lastPres -eq $presentationNow) {
        Write-Host "[vox-private] Nada novo em vox-private-content ($($currentCommit.Substring(0,8))) nem na apresentação — nada a fazer."
        return
    }

    # --- build (config temporária só para pôr o baseURL com o guid; o guid nunca vai para o git)
    $siteUrl = "https://vox.thluiz.com/privado/$guid/"
    $tmpCfg = Join-Path ([IO.Path]::GetTempPath()) "vox-private-$([guid]::NewGuid()).toml"
    $cfgText = (Get-Content -Raw -Encoding utf8 "$VOX_HUGO\hugo.private.toml") -replace '(?m)^baseURL = .*$', "baseURL = `"$siteUrl`""
    $cfgText = $cfgText -replace [regex]::Escape("E:/vox-private-content"), ($ContentDir -replace '\\', '/')
    [IO.File]::WriteAllText($tmpCfg, $cfgText, [Text.UTF8Encoding]::new($false))
    try {
        Write-Host '[vox-private] Build Hugo...'
        Set-Location $VOX_HUGO
        hugo --config $tmpCfg --destination $OutDir --cleanDestinationDir --logLevel warn
        if ($LASTEXITCODE -ne 0) { throw "build Hugo falhou (exit $LASTEXITCODE)" }
    } finally { Remove-Item -Force -ErrorAction SilentlyContinue $tmpCfg }

    $pageCount = (Get-ChildItem $OutDir -Recurse -Filter index.html -File | Measure-Object).Count
    if ($pageCount -lt 1) { throw 'build não gerou nenhuma página' }
    Write-Host "[vox-private] $pageCount página(s) geradas"

    # --- upload: sync só dentro do prefixo do guid (o --delete não alcança mais nada)
    Write-Host '[vox-private] Enviando para o S3...'
    $dest = "s3://$BUCKET/privado/$guid/"
    & $aws s3 sync $OutDir $dest @awsArgs --delete --cache-control 'private, max-age=300' --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "aws s3 sync falhou (exit $LASTEXITCODE)" }

    # --- portal: /privado/ pede a senha e leva ao site
    $portal = @"
<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>Vox privado</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:15vh auto;padding:0 1rem;color:#e5e7eb;background:#111827}a{color:#93c5fd}</style>
</head><body><h1>Vox privado</h1><p><a href="/privado/$guid/">Abrir o site privado</a></p></body></html>
"@
    $portalFile = Join-Path ([IO.Path]::GetTempPath()) "vox-private-portal-$([guid]::NewGuid()).html"
    [IO.File]::WriteAllText($portalFile, $portal, [Text.UTF8Encoding]::new($false))
    try {
        & $aws s3 cp $portalFile "s3://$BUCKET/privado/index.html" @awsArgs --content-type 'text/html; charset=utf-8' --cache-control 'no-store' --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "upload do portal falhou (exit $LASTEXITCODE)" }
    } finally { Remove-Item -Force -ErrorAction SilentlyContinue $portalFile }

    # --- invalidação (as regras privado e privado/* do CloudFront)
    Write-Host '[vox-private] Invalidando o cache do CloudFront...'
    & $aws cloudfront create-invalidation --distribution-id $DIST_ID --paths '/privado' '/privado/*' @($awsArgs | Where-Object { $_ -ne $S3_REGION -and $_ -ne '--region' }) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "invalidação falhou (exit $LASTEXITCODE)" }

    # --- conferência: o site responde mesmo?
    $ok = $false
    foreach ($try in 1..10) {
        try {
            $r = Invoke-WebRequest -Uri $siteUrl -Method Head -TimeoutSec 20 -SkipHttpErrorCheck
            if ([int]$r.StatusCode -eq 200) { $ok = $true; break }
            Write-Host "[vox-private] conferência $try/10: HTTP $([int]$r.StatusCode)"
        } catch { Write-Host "[vox-private] conferência $try/10: $($_.Exception.Message)" }
        Start-Sleep -Seconds 6
    }
    if (-not $ok) { throw 'o site privado não respondeu 200 depois do upload' }

    $currentCommit | Set-Content $lastCommitFile -Encoding UTF8
    $presentationNow | Set-Content $lastPresFile -Encoding UTF8
    Write-Host '[vox-private] Publicado com sucesso!'
    # Notificação genérica: sem título, sem URL (o guid é a credencial)
    Send-Gossip "🔒 <b>Vox privado publicado</b> — $pageCount páginas"
}
catch {
    Write-Error "FATAL: $_"
    Send-Gossip "🛑 <b>Vox privado: publish FALHOU</b>`n<code>$([System.Net.WebUtility]::HtmlEncode($_.ToString()))</code>"
    exit 1
}
finally {
    try { $lock.ReleaseMutex() } catch {}
    Stop-Transcript | Out-Null
}
