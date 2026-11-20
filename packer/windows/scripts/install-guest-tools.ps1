# Installs the virtio drivers and the QEMU guest agent from the virtio-win CD
# (virtio-win-guest-tools.exe), and fails unless the agent is running after.
$ErrorActionPreference = 'Stop'

$installer = Get-PSDrive -PSProvider FileSystem |
    ForEach-Object { Join-Path $_.Root 'virtio-win-guest-tools.exe' } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if (-not $installer) {
    throw 'virtio-win-guest-tools.exe is on no drive: the virtio-win CD is missing'
}

$p = Start-Process -FilePath $installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
# 3010 is success with a reboot pending.
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
    throw "virtio-win-guest-tools.exe exited $($p.ExitCode)"
}

Set-Service -Name QEMU-GA -StartupType Automatic
Start-Service -Name QEMU-GA
if ((Get-Service -Name QEMU-GA).Status -ne 'Running') {
    throw 'the QEMU guest agent is not running'
}
Write-Output "virtio-win guest tools installed from $installer"
