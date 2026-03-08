# vox-sync-blob.ps1
# Sincroniza E:\quartz\public para Azure Blob Storage (hermesptvox/$web)
# Requer: azcopy no PATH, az CLI autenticado
param(
    [string]$PublicDir    = "E:\quartz\public",
    [string]$AccountName  = "hermesptvox",
    [string]$ResourceGroup = "vox_group",
    [int]$SasHours        = 4
)

$ErrorActionPreference = "Stop"
$az = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'

if (-not (Test-Path $PublicDir)) {
    throw "PublicDir não encontrado: $PublicDir"
}

Write-Host "[vox-sync] Source: $PublicDir ($((Get-ChildItem $PublicDir -Recurse -File).Count) ficheiros)"

# Gerar SAS token
$expiry = (Get-Date).AddHours($SasHours).ToUniversalTime().ToString("yyyy-MM-ddTHH:mmZ")
$key    = & $az storage account keys list --account-name $AccountName --query "[0].value" --output tsv
$sas    = & $az storage account generate-sas `
    --account-name $AccountName `
    --account-key  $key `
    --permissions  acdlruw `
    --resource-types co `
    --services     b `
    --expiry       $expiry `
    --https-only   `
    --output tsv

Write-Host "[vox-sync] SAS gerado (expiry: $expiry)"

$url = "https://$AccountName.blob.core.windows.net/`$web?$sas"

Write-Host "[vox-sync] azcopy sync..."
azcopy sync $PublicDir $url --recursive --delete-destination=true

Write-Host "[vox-sync] Concluído."
