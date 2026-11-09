#requires -Version 7
# Registers the hourly gated private publish as \Claude\VoxPrivatePublish, at minute 30 so it does not
# collide with \Claude\VoxPublish (minute 00; both also serialize on the Global\VoxPublish mutex).
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
$start = (Get-Date).Date.AddHours((Get-Date).Hour).AddMinutes(30)
if ($start -lt (Get-Date)) { $start = $start.AddHours(1) }
$trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Hours 1)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive

Register-ScheduledTask -TaskName $name -TaskPath $path -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'Vox privado: build Hugo + upload S3 privado, a cada hora (min 30), so se algo mudou' -Force | Out-Null
Write-Host "registered $path$name, first run $start"
