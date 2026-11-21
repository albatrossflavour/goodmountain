# The last step of the build. Removes what only the build needed: the answer
# files, the build's Administrator logon, and WinRM. Then sysprep generalises
# the image with cloudbase-init's Unattend.xml and shuts the VM down, and
# wait-stopped.sh waits for that before Packer makes the template.
#
# WinRM carries this session, and its job object ends every process the
# session started, so WinRM's removal and sysprep run as a one-shot SYSTEM
# scheduled task. It expires half an hour after it starts, and Task Scheduler
# deletes it once expired, on a clone's first boot at the latest.
$ErrorActionPreference = 'Stop'

# The answer files. Setup keeps a copy of the build's own, credentials and all, as
# unattend-original.xml.
Remove-Item -Path 'C:\Windows\Panther\unattend.xml' -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'C:\Windows\Panther\unattend-original.xml' -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'C:\Windows\Panther\Unattend\*' -Recurse -Force -ErrorAction SilentlyContinue

# A clone's specialize pass caches the sysprep /unattend file as
# Panther\unattend.xml. It holds no secret, but it goes too: SetupComplete.cmd
# runs as SYSTEM once setup has finished, before anyone can log on, removes
# the cached copies, and then itself.
New-Item -ItemType Directory -Path 'C:\Windows\Setup\Scripts' -Force | Out-Null
@'
@echo off
del /f /q "%WINDIR%\Panther\unattend.xml" "%WINDIR%\Panther\unattend-original.xml" 2>nul
rd /s /q "%WINDIR%\Panther\Unattend" 2>nul
del /f /q "%~f0"
'@ | Set-Content -Path 'C:\Windows\Setup\Scripts\SetupComplete.cmd' -Encoding ascii

# cloudbase-init's log can hold user-data output, so only SYSTEM and
# Administrators read it, not Users.
$logs = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
icacls "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log" /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F'
if ($LASTEXITCODE -ne 0) {
    throw "icacls on $logs exited $LASTEXITCODE"
}

$seal = {
    Start-Sleep -Seconds 15
    # WinRM: its listeners, the firewall rule Packer opened, and the service.
    Remove-Item -Path WSMan:\Localhost\Listener\* -Recurse
    Remove-NetFirewallRule -DisplayName 'Packer WinRM'
    Set-Service -Name WinRM -StartupType Disabled
    Stop-Service -Name WinRM -Force
    # The built-in Administrator, by its SID, whatever it is called.
    Get-LocalUser | Where-Object { $_.SID -like '*-500' } | Disable-LocalUser
    & "$env:SystemRoot\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /unattend:"C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml"
}

$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($seal.ToString()))
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -EncodedCommand $encoded"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
$trigger.EndBoundary = (Get-Date).AddMinutes(30).ToString('s')
$settings = New-ScheduledTaskSettingsSet -DeleteExpiredTaskAfter (New-TimeSpan -Seconds 1)
Register-ScheduledTask -TaskName 'packer-seal' -Action $action -Trigger $trigger -Settings $settings -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force | Out-Null
Write-Output 'WinRM removal and sealing handed to the packer-seal task'
