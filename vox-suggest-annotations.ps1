#Requires -Version 7
# Daily script: pick random episodes without annotations, get AI suggestions, notify via Telegram

param(
    [int]$Count = 2
)

$ErrorActionPreference = 'Stop'

$VOX_CONTENT    = 'E:\vox-content'
$GOSSIP_URL     = 'http://localhost:8080/api/gossip-gate/send'
$SUGGEST_URL    = 'http://localhost:8080/api/vox-intelligence/presets/podcast/suggest-annotations'
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

# --- 2. Find episodes with transcript but no annotations ---
Log "Scanning episodes..."
$poolEN = [System.Collections.Generic.List[object]]::new()
$poolPT = [System.Collections.Generic.List[object]]::new()

$jsonFiles = Get-ChildItem $VOX_CONTENT -Recurse -Filter '*.json' -File
foreach ($f in $jsonFiles) {
    try {
        $raw = Get-Content $f.FullName -Raw -Encoding utf8
        $ep = $raw | ConvertFrom-Json

        # Must have transcript
        if (-not $ep.transcript -or $ep.transcript.Length -lt 100) { continue }

        # Must NOT have annotations (null, missing, or empty array)
        if ($ep.annotations -and $ep.annotations.Count -gt 0) { continue }

        $relPath = $f.FullName.Replace($VOX_CONTENT, '').TrimStart('\').Replace('\', '/')
        $entry = @{
            Path    = $f.FullName
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
        # skip malformed files
    }
}

Log "Candidates: $($poolEN.Count) EN, $($poolPT.Count) PT"

if (($poolEN.Count + $poolPT.Count) -eq 0) {
    Log "No candidates found. Exiting."
    exit 0
}

# --- 3. Select episodes: 1 EN + (N-1) PT, with fallback ---
$selected = [System.Collections.Generic.List[object]]::new()

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

Log "Selected $($selected.Count) episodes"

# --- 4. For each episode, call suggest-annotations and send Telegram ---
foreach ($item in $selected) {
    $ep = $item.Episode
    $relPath = $item.RelPath
    $title = if ($ep.metadata.title) { $ep.metadata.title } else { $relPath }
    $podcast = if ($ep.metadata.podcast) { $ep.metadata.podcast } else { '?' }
    $duration = if ($ep.metadata.duration) { $ep.metadata.duration } else { '?' }

    Log "Processing: $title"

    # Build request body
    $reqBody = @{
        episode = @{
            lang         = $item.Lang
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
            continue
        }

        $suggestions = @($parsed.suggestions)
        $stats = $parsed.stats
        Log "  Got $($suggestions.Count) suggestions"

        # Group by tier
        $tierIcon = @{ concept = '🔑'; data = '📊'; reflection = '💭' }
        $concepts    = @($suggestions | Where-Object { $_.tier -eq 'concept' })
        $data        = @($suggestions | Where-Object { $_.tier -eq 'data' })
        $reflections = @($suggestions | Where-Object { $_.tier -eq 'reflection' })

        # Build header (shared across message chunks)
        $header = @(
            "📝 <b>$([System.Web.HttpUtility]::HtmlEncode($title))</b>"
            "<i>$([System.Web.HttpUtility]::HtmlEncode($podcast)) · $duration</i>"
            "📂 $relPath"
            ""
        ) -join "`n"

        # Build suggestion lines: icon ts — title
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
                # Flush current chunk
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
            # Number the parts
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
    }
}

Log "Done. Processed $($selected.Count) episodes."
