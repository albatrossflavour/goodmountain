# Installs the pinned cloudbase-init MSI, checked against its sha256, as
# LocalSystem, then copies the three config files from the answer CD over the
# MSI's own. The URL and checksum come from windows.pkr.hcl.
$ErrorActionPreference = 'Stop'

$url = $env:CLOUDBASE_INIT_MSI_URL
$want = ($env:CLOUDBASE_INIT_MSI_CHECKSUM -replace '^sha256:', '').ToUpperInvariant()
if (-not $url -or $want -notmatch '^[0-9A-F]{64}$') {
    throw 'CLOUDBASE_INIT_MSI_URL and a sha256: CLOUDBASE_INIT_MSI_CHECKSUM are needed'
}

$msi = Join-Path $env:TEMP 'CloudbaseInitSetup.msi'
$log = Join-Path $env:TEMP 'cloudbase-init-install.log'
curl.exe -fsSL --retry 3 -o $msi $url
if ($LASTEXITCODE -ne 0) {
    throw "downloading $url failed with curl exit code $LASTEXITCODE"
}
$have = (Get-FileHash -Path $msi -Algorithm SHA256).Hash
if ($have -ne $want) {
    throw "the cloudbase-init MSI's sha256 is $have, not the pinned $want"
}

$p = Start-Process -FilePath msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$log`"", 'RUN_SERVICE_AS_LOCAL_SYSTEM=1' -Wait -PassThru
if ($p.ExitCode -ne 0) {
    throw "cloudbase-init's MSI exited $($p.ExitCode); see $log"
}
Remove-Item -Path $msi, $log -Force

$conf = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf'
$cd = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'PACKER' } | Select-Object -First 1
if (-not $cd) {
    throw 'the answer CD (label PACKER) is missing'
}
foreach ($file in 'cloudbase-init.conf', 'cloudbase-init-unattend.conf', 'Unattend.xml') {
    Copy-Item -Path "$($cd.DriveLetter):\$file" -Destination (Join-Path $conf $file) -Force
}
Write-Output "cloudbase-init installed, config from the answer CD in $conf"
