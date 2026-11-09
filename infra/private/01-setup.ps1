#requires -Version 7
# Private area of Vox (/privado): creates the private bucket, the KeyValueStore, the edge function
# and the response headers policy. Idempotent. Does NOT touch the public distribution (see 02).
. "$PSScriptRoot/common.ps1"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# --- bucket: private, encrypted, versioned
aws s3api head-bucket @script:AwsS3 --bucket $script:Bucket 2>$null
if ($LASTEXITCODE -ne 0) {
    aws s3api create-bucket @script:AwsS3 --bucket $script:Bucket --create-bucket-configuration "LocationConstraint=$($script:S3Region)" | Out-Null
    Assert-Ok 'create-bucket'
    Write-Host "created bucket $($script:Bucket)"
} else {
    Write-Host "bucket exists $($script:Bucket)"
}
aws s3api put-public-access-block @script:AwsS3 --bucket $script:Bucket `
    --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
Assert-Ok 'put-public-access-block'
aws s3api put-bucket-encryption @script:AwsS3 --bucket $script:Bucket `
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
Assert-Ok 'put-bucket-encryption'
aws s3api put-bucket-versioning @script:AwsS3 --bucket $script:Bucket --versioning-configuration Status=Enabled
Assert-Ok 'put-bucket-versioning'
$lifecycle = Write-Json @{ Rules = @(@{
    ID = 'expire-noncurrent'; Status = 'Enabled'; Filter = @{ Prefix = '' }
    NoncurrentVersionExpiration = @{ NoncurrentDays = 30 }
    AbortIncompleteMultipartUpload = @{ DaysAfterInitiation = 7 }
}) }
try { aws s3api put-bucket-lifecycle-configuration @script:AwsS3 --bucket $script:Bucket --lifecycle-configuration "file://$lifecycle"; Assert-Ok 'put-bucket-lifecycle' } finally { Remove-Item -Force $lifecycle }
Write-Host 'bucket hardened (no public access, SSE-S3, versioning, 30-day noncurrent expiry)'

# --- KeyValueStore
$kvsArn = Get-KvsArn
if (-not $kvsArn) {
    $kvsArn = aws cloudfront create-key-value-store @script:Aws --name $script:KvsName --query 'KeyValueStore.ARN' --output text
    Assert-Ok 'create-key-value-store'
    Write-Host "created KVS $kvsArn"
} else {
    Write-Host "KVS exists $kvsArn"
}

# --- edge function
$code = Join-Path $root 'edge/vox-private-edge.js'
$config = Write-Json @{
    Comment = 'Vox privado: Basic Auth no portal, guid no site, rewrite de URI'
    Runtime = 'cloudfront-js-2.0'
    KeyValueStoreAssociations = @{ Quantity = 1; Items = @(@{ KeyValueStoreARN = $kvsArn }) }
}
try {
    $etag = aws cloudfront describe-function @script:Aws --name $script:FunctionName --query ETag --output text 2>$null
    if ($LASTEXITCODE -ne 0) {
        aws cloudfront create-function @script:Aws --name $script:FunctionName --function-config "file://$config" --function-code "fileb://$code" | Out-Null
        Assert-Ok 'create-function'
        Write-Host "created function $($script:FunctionName)"
    } else {
        aws cloudfront update-function @script:Aws --name $script:FunctionName --if-match $etag --function-config "file://$config" --function-code "fileb://$code" | Out-Null
        Assert-Ok 'update-function'
        Write-Host "updated function $($script:FunctionName)"
    }
} finally { Remove-Item -Force -ErrorAction SilentlyContinue $config }
$etag = aws cloudfront describe-function @script:Aws --name $script:FunctionName --query ETag --output text
Assert-Ok 'describe-function'
$fnArn = aws cloudfront publish-function @script:Aws --name $script:FunctionName --if-match $etag --query 'FunctionSummary.FunctionMetadata.FunctionARN' --output text
Assert-Ok 'publish-function'
Write-Host "published $fnArn"

# --- response headers policy (applied only to /privado)
$rhpId = aws cloudfront list-response-headers-policies @script:Aws --type custom --query "ResponseHeadersPolicyList.Items[?ResponseHeadersPolicy.ResponseHeadersPolicyConfig.Name=='$($script:HeadersPolicy)'].ResponseHeadersPolicy.Id | [0]" --output text
Assert-Ok 'list-response-headers-policies'
if (-not $rhpId -or $rhpId -eq 'None') {
    $f = Write-Json @{
        Name = $script:HeadersPolicy
        Comment = 'Vox privado: no referrer, no indexing, nosniff, no framing, HSTS'
        SecurityHeadersConfig = @{
            ContentTypeOptions = @{ Override = $true }
            FrameOptions = @{ Override = $true; FrameOption = 'DENY' }
            ReferrerPolicy = @{ Override = $true; ReferrerPolicy = 'no-referrer' }
            StrictTransportSecurity = @{ Override = $true; AccessControlMaxAgeSec = 31536000; IncludeSubdomains = $false; Preload = $false }
        }
        CustomHeadersConfig = @{ Quantity = 1; Items = @(@{ Header = 'X-Robots-Tag'; Value = 'noindex, nofollow, noarchive'; Override = $true }) }
    }
    try { $rhpId = aws cloudfront create-response-headers-policy @script:Aws --response-headers-policy-config "file://$f" --query 'ResponseHeadersPolicy.Id' --output text; Assert-Ok 'create-response-headers-policy' } finally { Remove-Item -Force $f }
    Write-Host "created headers policy $rhpId"
} else {
    Write-Host "headers policy exists $rhpId"
}
Write-Host "done: bucket=$($script:Bucket) kvs=$kvsArn function=$fnArn headersPolicy=$rhpId"
