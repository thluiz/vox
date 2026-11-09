#requires -Version 7
# Adds the private area to the PUBLIC Vox distribution (vox.thluiz.com): a second S3 origin (the
# private bucket, same OAC) and two cache behaviors, "privado" and "privado/*", both guarded by the
# vox-private-edge function. The default behavior and the public origin are not touched. Idempotent.
#
# Before anything it saves the current distribution config to
# ~/.secrets/vox-private/distribution-before-<timestamp>.json. To roll back:
#   aws cloudfront update-distribution --id <id> --if-match <current etag> --distribution-config file://<saved>.DistributionConfig
. "$PSScriptRoot/common.ps1"

# --- lookups
$fnArn = aws cloudfront describe-function @script:Aws --name $script:FunctionName --stage LIVE --query 'FunctionSummary.FunctionMetadata.FunctionARN' --output text
Assert-Ok 'describe-function (run 01-setup.ps1 first)'
$rhpId = aws cloudfront list-response-headers-policies @script:Aws --type custom --query "ResponseHeadersPolicyList.Items[?ResponseHeadersPolicy.ResponseHeadersPolicyConfig.Name=='$($script:HeadersPolicy)'].ResponseHeadersPolicy.Id | [0]" --output text
Assert-Ok 'list-response-headers-policies'
if (-not $rhpId -or $rhpId -eq 'None') { throw 'headers policy not found (run 01-setup.ps1 first)' }
$distArn = "arn:aws:cloudfront::$($script:Account):distribution/$($script:DistributionId)"

# --- bucket policy first: when the behavior goes live the origin must already be readable
$policy = Write-Json @{
    Version = '2012-10-17'
    Statement = @(
        @{
            Sid = 'AllowCloudFrontRead'; Effect = 'Allow'
            Principal = @{ Service = 'cloudfront.amazonaws.com' }
            Action = 's3:GetObject'
            Resource = "arn:aws:s3:::$($script:Bucket)/*"
            Condition = @{ StringEquals = @{ 'AWS:SourceArn' = $distArn } }
        },
        @{
            Sid = 'DenyInsecureTransport'; Effect = 'Deny'
            Principal = '*'
            Action = 's3:*'
            Resource = @("arn:aws:s3:::$($script:Bucket)", "arn:aws:s3:::$($script:Bucket)/*")
            Condition = @{ Bool = @{ 'aws:SecureTransport' = 'false' } }
        }
    )
}
try { aws s3api put-bucket-policy @script:AwsS3 --bucket $script:Bucket --policy "file://$policy"; Assert-Ok 'put-bucket-policy' } finally { Remove-Item -Force $policy }
Write-Host 'bucket policy set (CloudFront read only from this distribution, TLS only)'

# --- current distribution config + backup
$raw = aws cloudfront get-distribution-config @script:Aws --id $script:DistributionId --output json | Out-String
Assert-Ok 'get-distribution-config'
$backupDir = Join-Path $script:SecretsDir 'vox-private'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$backup = Join-Path $backupDir ("distribution-before-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$raw | Set-Content -Encoding utf8NoBOM $backup
Write-Host "backup: $backup"

$resp = $raw | ConvertFrom-Json -AsHashtable -Depth 50
$etag = $resp.ETag
$cfg = $resp.DistributionConfig

function Copy-Deep($o) { return ($o | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable -Depth 50) }

$changed = $false

# --- origin
if (-not ($cfg.Origins.Items | Where-Object { $_.Id -eq $script:OriginId })) {
    $o = Copy-Deep $cfg.Origins.Items[0]
    $o.Id = $script:OriginId
    $o.DomainName = "$($script:Bucket).s3.$($script:S3Region).amazonaws.com"
    $cfg.Origins.Items = @($cfg.Origins.Items) + @($o)
    $cfg.Origins.Quantity = $cfg.Origins.Items.Count
    $changed = $true
    Write-Host "origin added: $($o.Id)"
} else { Write-Host 'origin already present' }

# --- behaviors
$have = @()
if ($cfg.CacheBehaviors.Quantity -gt 0) { $have = @($cfg.CacheBehaviors.Items | ForEach-Object { $_.PathPattern }) }
$items = @(); if ($cfg.CacheBehaviors.Quantity -gt 0) { $items = @($cfg.CacheBehaviors.Items) }
foreach ($pattern in @('privado', 'privado/*')) {
    if ($have -contains $pattern) { Write-Host "behavior already present: $pattern"; continue }
    $b = Copy-Deep $cfg.DefaultCacheBehavior
    $b.PathPattern = $pattern
    $b.TargetOriginId = $script:OriginId
    $b.ResponseHeadersPolicyId = $rhpId
    $b.CachePolicyId = $script:CachingOptimized
    $b.FunctionAssociations = @{ Quantity = 1; Items = @(@{ EventType = 'viewer-request'; FunctionARN = $fnArn }) }
    $items += $b
    $changed = $true
    Write-Host "behavior added: $pattern"
}
if ($changed) {
    $cfg.CacheBehaviors = @{ Quantity = $items.Count; Items = $items }
    $file = Write-Json $cfg
    try {
        aws cloudfront update-distribution @script:Aws --id $script:DistributionId --if-match $etag --distribution-config "file://$file" --query 'Distribution.Status' --output text
        Assert-Ok 'update-distribution'
    } finally { Remove-Item -Force $file }
    Write-Host 'distribution updated; waiting for deployment (a few minutes)...'
    aws cloudfront wait distribution-deployed @script:Aws --id $script:DistributionId
    Assert-Ok 'wait distribution-deployed'
    Write-Host 'distribution deployed'
} else {
    Write-Host 'nothing to change'
}
