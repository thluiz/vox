#Requires -Version 7
# Daily script: pick episode(s) without annotations, trigger Toscanini's
# annotate pipeline directly (same worker/model as auto_annotate feeds).
# No preview step here by design (see feedback_always_preview_annotations.md
# for why the OLD flow always previewed — this backlog flow was deliberately
# changed to skip it, matching what already runs live for other feeds).

param(
    [int]$Count = 1
)

$ErrorActionPreference = 'Stop'

$VOX_CONTENT    = 'E:\vox-content'
$GOSSIP_URL     = 'http://localhost:8080/api/gossip-gate/send'
$ANNOTATE_URL   = 'http://localhost:8080/api/orchestrator/annotate'
$API_KEY        = (Get-Content 'C:\Users\conta\.gossipgate\api-key' -Raw).Trim()
$LOG_FILE       = Join-Path $PSScriptRoot 'vox-suggest-annotations.log'

function Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts  $msg" | Out-File -Append -FilePath $LOG_FILE -Encoding utf8
    Write-Host $msg
}

function Send-Telegram($msg) {
    $body = @{ message = $msg; parse_mode = 'HTML' } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri $GOSSIP_URL -Method Post `
        -Headers @{ 'X-Api-Key' = $API_KEY; 'Content-Type' = 'application/json' } `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
}

# --- 1. Git pull ---
try {
    Push-Location $VOX_CONTENT
    $pullResult = git pull 2>&1
    Pop-Location
    Log "git pull: $pullResult"
} catch {
    Log "git pull failed: $_"
}

# --- 2. Find episodes from need-annotation list, with transcript but no annotations ---
Log "Scanning episodes..."
$poolEN = [System.Collections.Generic.List[object]]::new()
$poolPT = [System.Collections.Generic.List[object]]::new()

$needAnnotationFile = Join-Path $PSScriptRoot 'need-annotation.json'
if (-not (Test-Path $needAnnotationFile)) {
    $msg = "Ficheiro need-annotation.json não encontrado em $PSScriptRoot"
    Log $msg
    Send-Telegram $msg
    exit 0
}
$needList = Get-Content $needAnnotationFile -Raw -Encoding utf8 | ConvertFrom-Json
$needSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($p in $needList) { [void]$needSet.Add($p) }
Log "need-annotation.json: $($needSet.Count) entries"

foreach ($relPath in $needList) {
    $fullPath = Join-Path $VOX_CONTENT ($relPath -replace '/', '\')
    if (-not (Test-Path $fullPath)) {
        Log "  SKIP (not found): $relPath"
        continue
    }
    try {
        $raw = Get-Content $fullPath -Raw -Encoding utf8
        $ep = $raw | ConvertFrom-Json

        # Must have transcript
        if (-not $ep.transcript -or $ep.transcript.Length -lt 100) { continue }

        # Must NOT have annotations (null, missing, or empty array)
        if ($ep.annotations -and $ep.annotations.Count -gt 0) { continue }

        $entry = @{
            Path    = $fullPath
            RelPath = $relPath
            Lang    = if ($ep.lang) { $ep.lang } else { 'pt' }
            Episode = $ep
        }

        if ($entry.Lang -match '^en') {
            $poolEN.Add($entry)
        } else {
            $poolPT.Add($entry)
        }
    } catch {
        Log "  SKIP (parse error): $relPath"
    }
}

$totalPool = $poolEN.Count + $poolPT.Count
Log "Candidates: $($poolEN.Count) EN, $($poolPT.Count) PT (need-annotation pool)"

if ($totalPool -eq 0) {
    $msg = "Nenhum episódio marcado com need-annotation. Marque episódios para receber sugestões."
    Log $msg
    Send-Telegram $msg
    exit 0
}

# --- 3. Select episodes: 1 EN + (N-1) PT, with fallback ---
$selected = [System.Collections.Generic.List[object]]::new()

if ($Count -eq 1) {
    # Single pick: draw from both pools combined so language varies day to day
    $combined = @($poolEN) + @($poolPT)
    if ($combined.Count -gt 0) {
        $selected.Add(($combined | Get-Random))
    }
} else {
    $enCount = [Math]::Min(1, $poolEN.Count)
    $ptCount = [Math]::Min($Count - $enCount, $poolPT.Count)

    # If one pool is short, fill from the other
    if ($enCount + $ptCount -lt $Count) {
        $remaining = $Count - $enCount - $ptCount
        if ($poolEN.Count -gt $enCount) {
            $extra = [Math]::Min($remaining, $poolEN.Count - $enCount)
            $enCount += $extra
            $remaining -= $extra
        }
        if ($remaining -gt 0 -and $poolPT.Count -gt $ptCount) {
            $extra = [Math]::Min($remaining, $poolPT.Count - $ptCount)
            $ptCount += $extra
        }
    }

    if ($enCount -gt 0) {
        $shuffledEN = $poolEN | Get-Random -Count $enCount
        if ($enCount -eq 1) { $selected.Add($shuffledEN) } else { $selected.AddRange(@($shuffledEN)) }
    }
    if ($ptCount -gt 0) {
        $shuffledPT = $poolPT | Get-Random -Count $ptCount
        if ($ptCount -eq 1) { $selected.Add($shuffledPT) } else { $selected.AddRange(@($shuffledPT)) }
    }
}

Log "Selected $($selected.Count) episodes"

# --- 4. For each episode, trigger Toscanini's annotate pipeline directly ---
# (suggest_annotations + annotate + merge + git commit + publish all happen
# inside Toscanini itself — this script only fires the job and reports it.
# The final Telegram, with the published link, comes from Toscanini's own
# NotifyWorker once the pipeline finishes, ~1-2 min later.)
foreach ($item in $selected) {
    $ep = $item.Episode
    $relPath = $item.RelPath
    $title = if ($ep.metadata.title) { $ep.metadata.title } else { $relPath }
    $podcast = if ($ep.metadata.podcast) { $ep.metadata.podcast } else { '?' }
    $epPath = $relPath -replace '\.json$', ''

    Log "Processing: $title"

    $reqBody = @{ path = $epPath } | ConvertTo-Json -Compress

    try {
        $resp = Invoke-RestMethod -Uri $ANNOTATE_URL -Method Post `
            -Headers @{ 'Content-Type' = 'application/json' } `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($reqBody)) `
            -TimeoutSec 30

        Log "  Job aceito: $($resp.job_id) (status=$($resp.status))"

        $startMsg = @(
            "🎙️ <b>$([System.Web.HttpUtility]::HtmlEncode($title))</b>"
            "<i>$([System.Web.HttpUtility]::HtmlEncode($podcast))</i>"
            "📂 $epPath"
            ""
            "Anotando agora via Toscanini (sem preview) — publicação e anotações chegam num Telegram separado em ~1-2 min."
        ) -join "`n"
        Send-Telegram $startMsg

    } catch {
        Log "  ERROR for ${title}: $_"
        Send-Telegram "❌ Falha ao anotar <b>$([System.Web.HttpUtility]::HtmlEncode($title))</b>: $_"
    }
}

# --- 5. Clean up need-annotation.json (remove already-annotated) ---
$stillPending = [System.Collections.Generic.List[string]]::new()
foreach ($relPath in $needList) {
    $fullPath = Join-Path $VOX_CONTENT ($relPath -replace '/', '\')
    if (-not (Test-Path $fullPath)) { continue }
    try {
        $raw = Get-Content $fullPath -Raw -Encoding utf8
        $ep = $raw | ConvertFrom-Json
        if ($ep.annotations -and $ep.annotations.Count -gt 0) { continue }
        if (-not $ep.transcript -or $ep.transcript.Length -lt 100) { continue }
        $stillPending.Add($relPath)
    } catch { }
}
$removed = $needSet.Count - $stillPending.Count
if ($removed -gt 0) {
    $stillPending | ConvertTo-Json | Set-Content $needAnnotationFile -Encoding utf8
    Log "Cleaned need-annotation.json: removed $removed already-annotated entries"
}

# --- 6. Report remaining pool size ---
Send-Telegram "📋 $($stillPending.Count) episódios com need-annotation aguardando anotação"

Log "Done. Processed $($selected.Count) episodes. $($stillPending.Count) remaining in pool."
