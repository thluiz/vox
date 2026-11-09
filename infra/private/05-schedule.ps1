#requires -Version 7
# Registers the gated private publish as \Claude\VoxPrivatePublish, every 15 minutes (the gate makes a run
# with nothing new cost one git fetch). It serializes with \Claude\VoxPublish on the Global\VoxPublish mutex.
# Same shape as VoxPublish: wscript shim, interactive user token, IgnoreNew, 1h limit.
param([switch]$Remove)

$name = 'VoxPrivatePublish'
$path = '\Claude\'

if ($Remove) {
    Unregister-ScheduledTask -TaskName $name -TaskPath $path -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "removed $path$name"
    return
}

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '"E:\vox\vox-publish-private-hidden.vbs"'
$now = Get-Date
$start = $now.Date.AddHours($now.Hour).AddMinutes([math]::Ceiling($now.Minute / 15) * 15)
$trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes 15)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

Register-ScheduledTask -TaskName $name -TaskPath $path -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'Vox privado: build Hugo + upload S3 privado, a cada 15 min, so se algo mudou' -Force | Out-Null
Write-Host "registered $path$name, every 15 minutes from $start"
