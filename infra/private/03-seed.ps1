#requires -Version 7
# Seeds the private area credentials. Keeps the site guid and the portal password in
# C:\Users\conta\.secrets\vox-private.json (never versioned) and writes only what the edge
# needs to the KeyValueStore: sha256 of the Basic Auth header ("pw") and the allowed guid ("t:<guid>").
# Never prints the guid or the password. -Rotate generates new ones and revokes the old guid.
param([switch]$Rotate)
. "$PSScriptRoot/common.ps1"

New-Item -ItemType Directory -Force -Path $script:SecretsDir | Out-Null

$old = $null
if (Test-Path $script:SecretsFile) { $old = Get-Content -Raw -Encoding utf8 $script:SecretsFile | ConvertFrom-Json }

if ($old -and -not $Rotate) {
    $cred = $old
    Write-Host 'secrets file exists, reusing (use -Rotate to replace)'
} else {
    $bytes = [byte[]]::new(18)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $cred = [pscustomobject]@{
        guid     = [guid]::NewGuid().ToString()
        user     = 'privado'
        password = [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_')
    }
    $cred | ConvertTo-Json | Set-Content -Encoding utf8 $script:SecretsFile
    Write-Host "credentials generated at $($script:SecretsFile)"
}

$header = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($cred.user):$($cred.password)"))
$hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($header))).ToLowerInvariant()

$kvsArn = Get-KvsArn
if (-not $kvsArn) { throw "KVS $($script:KvsName) not found (run 01-setup.ps1 first)" }
$etag = aws cloudfront-keyvaluestore describe-key-value-store @script:Aws --kvs-arn $kvsArn --query ETag --output text
Assert-Ok 'describe-key-value-store'

$puts = @(@{ Key = 'pw'; Value = $hash }, @{ Key = "t:$($cred.guid)"; Value = '1' })
$deletes = @()
if ($old -and $Rotate -and $old.guid -ne $cred.guid) { $deletes = @(@{ Key = "t:$($old.guid)" }) }

$args2 = @('--kvs-arn', $kvsArn, '--if-match', $etag)
$putFile = Write-Json $puts
try {
    if ($deletes.Count -gt 0) {
        $delFile = Write-Json $deletes
        try { aws cloudfront-keyvaluestore update-keys @script:Aws @args2 --puts "file://$putFile" --deletes "file://$delFile" | Out-Null; Assert-Ok 'update-keys' } finally { Remove-Item -Force $delFile }
        Write-Host 'old guid revoked'
    } else {
        aws cloudfront-keyvaluestore update-keys @script:Aws @args2 --puts "file://$putFile" | Out-Null
        Assert-Ok 'update-keys'
    }
} finally { Remove-Item -Force $putFile }
Write-Host 'KVS seeded: pw hash and the site guid (values not printed)'
