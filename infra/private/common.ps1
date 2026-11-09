# Shared helpers for the private-area infra scripts (dot-source this file).
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:PYTHONUTF8 = '1'

$script:Profile        = 'scholion-admin'
$script:CfRegion       = 'us-east-1'            # CloudFront / KeyValueStore API
$script:S3Region       = 'sa-east-1'            # same region as hermes-vox-br
$script:Account        = '137566891486'
$script:DistributionId = 'EBJV9APC86R77'        # vox.thluiz.com
$script:Bucket         = 'hermes-vox-private-br'
$script:OriginId       = 'hermes-vox-private-s3'
$script:KvsName        = 'vox-private-kvs'
$script:FunctionName   = 'vox-private-edge'
$script:HeadersPolicy  = 'vox-private-headers'
$script:CachingOptimized = '658327ea-f89d-4fab-a63d-7e88639e58f6'
$script:SecretsDir     = Join-Path $HOME '.secrets'
$script:SecretsFile    = Join-Path $script:SecretsDir 'vox-private.json'

$script:Aws   = @('--profile', $script:Profile, '--region', $script:CfRegion)
$script:AwsS3 = @('--profile', $script:Profile, '--region', $script:S3Region)

function Assert-Ok([string]$what) {
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" }
}

# Writes an object as JSON to a temp file and returns the path (caller removes it).
function Write-Json($obj) {
    $path = Join-Path ([IO.Path]::GetTempPath()) "vox-private-$([guid]::NewGuid()).json"
    ConvertTo-Json -InputObject $obj -Depth 20 | Set-Content -Encoding utf8NoBOM $path
    return $path
}

function Get-KvsArn {
    $arn = aws cloudfront list-key-value-stores @script:Aws --query "KeyValueStoreList.Items[?Name=='$($script:KvsName)'].ARN | [0]" --output text
    Assert-Ok 'list-key-value-stores'
    if (-not $arn -or $arn -eq 'None') { return $null }
    return $arn
}
