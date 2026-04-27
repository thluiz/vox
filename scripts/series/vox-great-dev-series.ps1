#Requires -Version 7
# Daily script: suggest annotations for Great Developer series episodes, one per day

$ErrorActionPreference = 'Stop'

$VOX_CONTENT    = 'E:\vox-content'
$GOSSIP_URL     = 'http://localhost:8080/api/gossip-gate/send'
$SUGGEST_URL    = 'http://localhost:8080/api/vox-intelligence/presets/podcast/suggest-annotations'
$API_KEY        = (Get-Content 'C:\Users\conta\.gossipgate\api-key' -Raw).Trim()
$LOG_FILE       = Join-Path $PSScriptRoot 'vox-great-dev-series.log'
$STATE_FILE     = Join-Path $PSScriptRoot 'vox-great-dev-series.next'

$EPISODES = @(
    '2016/06/W23/great-developer-mindset-redefining-complete'
    '2017/09/W37/dcr-traits-of-a-great-developer-grit-of-a-scientist'
    '2017/09/W37/dcr-traits-of-a-great-developer-humility'
    '2017/09/W38/dcr-traits-of-a-great-developer-communications-expert'
    '2017/09/W38/dcr-traits-of-a-great-developer-communications-model-deep-dive'
    '2017/09/W38/dcr-traits-of-a-great-developer-expanding-perspective'
    '2018/10/W40/why-great-developer-still-google-their-errors'
)

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

# --- 1. Read state ---
if (-not (Test-Path $STATE_FILE)) {
    '0' | Set-Content $STATE_FILE -NoNewline
}
$index = [int](Get-Content $STATE_FILE -Raw).Trim()

if ($index -ge $EPISODES.Count) {
    Log "Series complete ($index >= $($EPISODES.Count)). Nothing to do."
    Send-Telegram "✅ <b>Great Developer Series</b> — série completa! Todas as $($EPISODES.Count) sugestões foram enviadas."
    exit 0
}

$slug = $EPISODES[$index]
$jsonPath = Join-Path $VOX_CONTENT "$slug.json"
$relPath = "$slug.json"

Log "Episode $($index + 1)/$($EPISODES.Count): $slug"

# --- 2. Git pull ---
try {
    Push-Location $VOX_CONTENT
    $pullResult = git pull 2>&1
    Pop-Location
    Log "git pull: $pullResult"
} catch {
    Log "git pull failed: $_"
}

# --- 3. Load episode JSON ---
if (-not (Test-Path $jsonPath)) {
    Log "ERROR: File not found: $jsonPath"
    Send-Telegram "❌ <b>Great Developer Series</b> — ficheiro não encontrado: <code>$relPath</code>"
    exit 1
}

$raw = Get-Content $jsonPath -Raw -Encoding utf8
$ep = $raw | ConvertFrom-Json

$title = if ($ep.metadata.title) { $ep.metadata.title } else { $slug }
$podcast = if ($ep.metadata.podcast) { $ep.metadata.podcast } else { '?' }
$duration = if ($ep.metadata.duration) { $ep.metadata.duration } else { '?' }
$lang = if ($ep.lang) { $ep.lang } else { 'en' }

if (-not $ep.transcript -or $ep.transcript.Length -lt 100) {
    Log "ERROR: No transcript for $title"
    Send-Telegram "❌ <b>Great Developer Series</b> — sem transcript: <code>$relPath</code>"
    exit 1
}

Log "Processing: $title ($lang)"

# --- 4. Call suggest-annotations ---
$reqBody = @{
    episode = @{
        lang         = $lang
        summary      = if ($ep.summary) { $ep.summary } else { '' }
        annotations  = @()
        transcript   = $ep.transcript
        metadata     = @{
            title    = $title
            podcast  = $podcast
            duration = $duration
        }
        participants = [array]@(if ($ep.participants) { $ep.participants } else { @() })
    }
} | ConvertTo-Json -Depth 5 -Compress

try {
    $resp = Invoke-RestMethod -Uri $SUGGEST_URL -Method Post `
        -Headers @{ 'Content-Type' = 'application/json' } `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($reqBody)) `
        -TimeoutSec 120

    $parsed = $resp.'x-parsed'
    if (-not $parsed -or -not $parsed.suggestions) {
        Log "  No suggestions returned for $title"
        Send-Telegram "⚠️ <b>Great Developer Series</b> ($($index+1)/$($EPISODES.Count)) — sem sugestões para: <code>$relPath</code>"
        # Still increment so we don't get stuck
        $nextIndex = $index + 1
        "$nextIndex" | Set-Content $STATE_FILE -NoNewline
        exit 0
    }

    $suggestions = @($parsed.suggestions)
    Log "  Got $($suggestions.Count) suggestions"

    # Group by tier
    $tierIcon = @{ concept = '🔑'; data = '📊'; reflection = '💭' }

    # Build header
    $header = @(
        "📝 <b>Great Developer Series</b> ($($index+1)/$($EPISODES.Count))"
        ""
        "<b>$([System.Web.HttpUtility]::HtmlEncode($title))</b>"
        "<i>$([System.Web.HttpUtility]::HtmlEncode($podcast)) · $duration</i>"
        "📂 $relPath"
        ""
    ) -join "`n"

    # Build suggestion lines
    $suggLines = [System.Collections.Generic.List[string]]::new()
    foreach ($tier in @('concept', 'data', 'reflection')) {
        $group = @($suggestions | Where-Object { $_.tier -eq $tier })
        if ($group.Count -eq 0) { continue }
        foreach ($s in $group) {
            $icon = $tierIcon[$tier]
            $escapedTitle = [System.Web.HttpUtility]::HtmlEncode($s.title)
            $suggLines.Add("$icon <code>$($s.ts)</code> — $escapedTitle")
        }
    }

    $allTs = ($suggestions | Sort-Object { $_.ts } | ForEach-Object { $_.ts }) -join ', '
    $footer = "`nTotal: $($suggestions.Count) sugestões`n<code>$allTs</code>"

    # Split into messages respecting 4096 char limit
    $LIMIT = 4000
    $msgs = [System.Collections.Generic.List[string]]::new()
    $current = $header
    $partNum = 0

    foreach ($line in $suggLines) {
        $candidate = if ($current.Length -eq $header.Length) { "$current$line" } else { "$current`n$line" }
        if ($candidate.Length + $footer.Length -gt $LIMIT -and $current.Length -gt $header.Length) {
            $partNum++
            $msgs.Add($current)
            $current = $header + $line
        } else {
            $current = $candidate
        }
    }
    # Add footer to last chunk
    $current += $footer
    if ($msgs.Count -gt 0) {
        for ($i = 0; $i -lt $msgs.Count; $i++) {
            $msgs[$i] += "`n<i>($($i+1)/$($msgs.Count+1))</i>"
        }
        $current += "`n<i>($($msgs.Count+1)/$($msgs.Count+1))</i>"
    }
    $msgs.Add($current)

    foreach ($m in $msgs) {
        Send-Telegram $m
    }

    # Send ready-to-use /podcast-annotate command
    $epPath = $relPath -replace '\.json$', ''
    $cmdMsg = "<code>/podcast-annotate `"$epPath`" `"$allTs`"</code>"
    Send-Telegram $cmdMsg
    Log "  Sent $($msgs.Count + 1) message(s) for $title"

} catch {
    Log "  ERROR for ${title}: $_"
    Send-Telegram "❌ <b>Great Developer Series</b> ($($index+1)/$($EPISODES.Count)) — erro ao processar: <code>$relPath</code>`n<pre>$_</pre>"
}

# --- 5. Increment state ---
$nextIndex = $index + 1
"$nextIndex" | Set-Content $STATE_FILE -NoNewline
Log "State updated: next index = $nextIndex"
