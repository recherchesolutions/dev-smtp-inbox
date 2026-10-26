<#
.SYNOPSIS
  Publishes Fake SMTP and installs it as a Windows service with NSSM.

.DESCRIPTION
  Builds the app into -InstallDir (unless -SkipPublish), then registers it with NSSM as a delayed-auto-start
  service running as NT AUTHORITY\LocalService. The service gets read access to -InstallDir and write access
  to -MailFolder and -LogFolder only. Settings are passed as environment variables, so appsettings.json in the
  install folder stays as published. Re-running replaces an existing service of the same name; stored mail is kept.

  Run from an elevated PowerShell. Requires the .NET 10 SDK (for publishing) and nssm.exe.

.EXAMPLE
  .\scripts\install-service.ps1
.EXAMPLE
  .\scripts\install-service.ps1 -SmtpPort 2525 -WebPort 8025 -MailFolder D:\FakeSmtp\mail -MaxMessages 5000
#>
[CmdletBinding()]
param(
  [string]$NssmPath    = 'C:\Tools\nssm.exe',
  [string]$ServiceName = 'FakeSmtp',
  [string]$InstallDir  = (Join-Path (Split-Path $PSScriptRoot -Parent) 'publish'),
  [string]$MailFolder  = (Join-Path (Split-Path $PSScriptRoot -Parent) 'mail'),
  [string]$LogFolder   = (Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'),
  [int]$SmtpPort       = 25,
  [int]$WebPort        = 5025,
  [int]$MaxMessages    = 0,
  [string]$Account     = 'NT AUTHORITY\LocalService',
  [switch]$SkipPublish
)
$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script from an elevated (Administrator) PowerShell.' }
if (-not (Test-Path $NssmPath)) { throw "nssm.exe not found at $NssmPath. Download it from https://nssm.cc/ or pass -NssmPath." }

function Invoke-Nssm { & $NssmPath @args | Out-Null; if ($LASTEXITCODE -ne 0) { throw "nssm $($args -join ' ') failed ($LASTEXITCODE)" } }

# Replace an existing service of the same name (stop it first so the files and ports are free).
if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
  Write-Host "Removing existing service $ServiceName"
  Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
  & $NssmPath remove $ServiceName confirm | Out-Null
  if ($LASTEXITCODE -ne 0) { & sc.exe delete $ServiceName | Out-Null }
  Start-Sleep -Seconds 2
}

foreach ($port in $SmtpPort, $WebPort) {
  $busy = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
  if ($busy) { throw "Port $port is already in use (process id $($busy[0].OwningProcess)). Pick another with -SmtpPort / -WebPort." }
}

$project = Split-Path $PSScriptRoot -Parent
if (-not $SkipPublish) {
  Write-Host "Publishing to $InstallDir"
  & dotnet publish $project -c Release -o $InstallDir --nologo
  if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
}
$exe = Join-Path $InstallDir 'FakeSmtp.exe'
if (-not (Test-Path $exe)) { throw "$exe not found; publish first or drop -SkipPublish." }

New-Item -ItemType Directory -Force -Path $MailFolder, $LogFolder | Out-Null
& icacls $InstallDir /grant "${Account}:(OI)(CI)RX" /T /Q | Out-Null
& icacls $MailFolder /grant "${Account}:(OI)(CI)M" /T /Q | Out-Null
& icacls $LogFolder /grant "${Account}:(OI)(CI)M" /T /Q | Out-Null

Write-Host "Installing service $ServiceName"
Invoke-Nssm install $ServiceName $exe
Invoke-Nssm set $ServiceName AppDirectory $InstallDir
Invoke-Nssm set $ServiceName DisplayName 'Fake SMTP (local dev email catcher)'
Invoke-Nssm set $ServiceName Description "Stores all mail sent to 127.0.0.1:$SmtpPort; viewer at http://127.0.0.1:$WebPort. Nothing is delivered."
Invoke-Nssm set $ServiceName Start SERVICE_DELAYED_AUTO_START
Invoke-Nssm set $ServiceName ObjectName $Account
Invoke-Nssm set $ServiceName AppEnvironmentExtra `
  "FakeSmtp__SmtpPort=$SmtpPort" `
  "FakeSmtp__MailFolder=$MailFolder" `
  "FakeSmtp__MaxMessages=$MaxMessages" `
  "Urls=http://127.0.0.1:$WebPort"
Invoke-Nssm set $ServiceName AppStdout (Join-Path $LogFolder 'service.log')
Invoke-Nssm set $ServiceName AppStderr (Join-Path $LogFolder 'service.log')
Invoke-Nssm set $ServiceName AppRotateFiles 1
Invoke-Nssm set $ServiceName AppRotateBytes 10485760
Invoke-Nssm set $ServiceName AppExit Default Restart
Invoke-Nssm set $ServiceName AppRestartDelay 5000

Start-Service $ServiceName
Start-Sleep -Seconds 3
Get-Service $ServiceName | Format-Table Status, StartType, Name -AutoSize
Write-Host "SMTP:   127.0.0.1:$SmtpPort"
Write-Host "Viewer: http://127.0.0.1:$WebPort"
Write-Host "Mail:   $MailFolder"
Write-Host "Logs:   $LogFolder"
