#requires -Version 7
# Least-privilege IAM user for the scheduled private publish (vox-publish-private.ps1):
# read/write/delete only under privado/ of the private bucket, plus invalidations on the Vox
# distribution. The access key goes into C:\Users\conta\.secrets\vox-private.json ("aws" key),
# next to the guid and the portal password. Never printed. Idempotent; -RotateKey replaces the key.
param([switch]$RotateKey)
. "$PSScriptRoot/common.ps1"

$user = 'vox-private-deploy'
$distArn = "arn:aws:cloudfront::$($script:Account):distribution/$($script:DistributionId)"

aws iam get-user @script:Aws --user-name $user 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    aws iam create-user @script:Aws --user-name $user | Out-Null
    Assert-Ok 'create-user'
    Write-Host "created user $user"
} else { Write-Host "user exists $user" }

$policy = Write-Json @{
    Version = '2012-10-17'
    Statement = @(
        @{ Effect = 'Allow'; Action = @('s3:GetBucketLocation'); Resource = "arn:aws:s3:::$($script:Bucket)" },
        @{ Effect = 'Allow'; Action = @('s3:ListBucket'); Resource = "arn:aws:s3:::$($script:Bucket)"
           Condition = @{ StringLike = @{ 's3:prefix' = @('privado/*', 'privado') } } },
        @{ Effect = 'Allow'; Action = @('s3:GetObject', 's3:PutObject', 's3:DeleteObject'); Resource = "arn:aws:s3:::$($script:Bucket)/privado/*" },
        @{ Effect = 'Allow'; Action = @('cloudfront:CreateInvalidation', 'cloudfront:GetInvalidation'); Resource = $distArn }
    )
}
try { aws iam put-user-policy @script:Aws --user-name $user --policy-name vox-private-publish --policy-document "file://$policy"; Assert-Ok 'put-user-policy' } finally { Remove-Item -Force $policy }
Write-Host 'policy set (s3 under privado/ only + CreateInvalidation)'

New-Item -ItemType Directory -Force -Path $script:SecretsDir | Out-Null
$cred = $null
if (Test-Path $script:SecretsFile) { $cred = Get-Content -Raw -Encoding utf8 $script:SecretsFile | ConvertFrom-Json -AsHashtable }
if (-not $cred) { throw "run 03-seed.ps1 first (secrets file missing)" }

$haveKey = $cred.ContainsKey('aws') -and $cred.aws.accessKeyId -and $cred.aws.secretAccessKey
if ($haveKey -and -not $RotateKey) {
    Write-Host 'access key already stored, reusing (use -RotateKey to replace)'
} else {
    $existing = aws iam list-access-keys @script:Aws --user-name $user --query 'AccessKeyMetadata[].AccessKeyId' --output text
    Assert-Ok 'list-access-keys'
    foreach ($id in ($existing -split '\s+' | Where-Object { $_ })) {
        aws iam delete-access-key @script:Aws --user-name $user --access-key-id $id | Out-Null
        Assert-Ok 'delete-access-key'
    }
    $key = aws iam create-access-key @script:Aws --user-name $user --output json | ConvertFrom-Json
    Assert-Ok 'create-access-key'
    $cred['aws'] = @{ accessKeyId = $key.AccessKey.AccessKeyId; secretAccessKey = $key.AccessKey.SecretAccessKey }
    $cred | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $script:SecretsFile
    Write-Host 'access key created and stored (not printed)'
}
