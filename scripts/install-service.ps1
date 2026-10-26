<#
.SYNOPSIS
  Publishes Fake SMTP and installs it as a Windows service with NSSM.

.DESCRIPTION
  Asks where received emails should be stored (unless -MailFolder or -NoPrompt is given), builds the app into
  -InstallDir (unless -SkipPublish), writes the chosen settings into <InstallDir>\appsettings.json, and registers
  the app with NSSM as a delayed-auto-start service running as NT AUTHORITY\LocalService. The service gets read
  access to -InstallDir and write access to the mail and log folders only.

  Re-running replaces the service and keeps your settings: the mail folder, ports and message limit default to the
  values the installed copy already uses. If the mail folder changes, stored messages can be moved to the new one.

  To change settings later without reinstalling, edit <InstallDir>\appsettings.json and run Restart-Service.

  Run from an elevated PowerShell. Requires the .NET 10 SDK (for publishing) and nssm.exe.

.EXAMPLE
  .\scripts\install-service.ps1
.EXAMPLE
  .\scripts\install-service.ps1 -MailFolder D:\FakeSmtp\mail -SmtpPort 2525 -WebPort 8025 -MaxMessages 5000
.EXAMPLE
  .\scripts\install-service.ps1 -NoPrompt     # unattended: keep current / default settings
#>
[CmdletBinding()]
param(
  [string]$NssmPath    = 'C:\Tools\nssm.exe',
  [string]$ServiceName = 'FakeSmtp',
  [string]$InstallDir,     # default: <repo>\publish
  [string]$MailFolder,     # default: asks; current setting or <repo>\mail
  [string]$LogFolder,      # default: <repo>\logs
  [int]$SmtpPort       = 25,
  [int]$WebPort        = 5025,
  [int]$MaxMessages    = 0,
  [string]$Account     = 'NT AUTHORITY\LocalService',
  [switch]$SkipPublish,
  [switch]$NoPrompt
)
$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script from an elevated (Administrator) PowerShell.' }
if (-not (Test-Path $NssmPath)) { throw "nssm.exe not found at $NssmPath. Download it from https://nssm.cc/download (copy win64\nssm.exe to C:\Tools) or pass -NssmPath." }

# $PSScriptRoot is empty in param() defaults under "powershell -File" (Windows PowerShell 5.1), so derive paths here.
$project = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
if (-not $InstallDir) { $InstallDir = Join-Path $project 'publish' }
if (-not $LogFolder) { $LogFolder = Join-Path $project 'logs' }
$configPath = Join-Path $InstallDir 'appsettings.json'
$interactive = -not $NoPrompt -and [Environment]::UserInteractive -and -not ([Environment]::GetCommandLineArgs() -match '^-NonI')

function Invoke-Nssm { & $NssmPath @args | Out-Null; if ($LASTEXITCODE -ne 0) { throw "nssm $($args -join ' ') failed ($LASTEXITCODE)" } }

# nssm writes UTF-16 to a pipe; read it with the matching console encoding.
function Get-NssmValue([string]$Name) {
  $saved = [Console]::OutputEncoding
  try { [Console]::OutputEncoding = [Text.Encoding]::Unicode; return (& $NssmPath get $ServiceName $Name 2>$null) }
  finally { [Console]::OutputEncoding = $saved }
}

function Resolve-FullPath([string]$Path, [string]$Base) { [IO.Path]::GetFullPath([IO.Path]::Combine($Base, $Path)) }

# --- Current settings (from the installed copy), used as defaults --------------------------------------------
$current = @{ MailFolder = (Join-Path $project 'mail'); SmtpPort = 25; WebPort = 5025; MaxMessages = 0 }
if (Test-Path $configPath) {
  $installed = Get-Content $configPath -Raw | ConvertFrom-Json
  if ($installed.FakeSmtp.MailFolder) { $current.MailFolder = Resolve-FullPath $installed.FakeSmtp.MailFolder $InstallDir }
  if ($installed.FakeSmtp.SmtpPort) { $current.SmtpPort = [int]$installed.FakeSmtp.SmtpPort }
  if ($installed.FakeSmtp.MaxMessages -ne $null) { $current.MaxMessages = [int]$installed.FakeSmtp.MaxMessages }
  if ($installed.Urls -match ':(\d+)/?$') { $current.WebPort = [int]$Matches[1] }
}
# Installs made by earlier versions of this script passed the settings as environment variables; those win.
if (Get-Service $ServiceName -ErrorAction SilentlyContinue) {
  foreach ($line in @(Get-NssmValue 'AppEnvironmentExtra')) {
    if ($line -match '^FakeSmtp__MailFolder=(.+)$') { $current.MailFolder = $Matches[1].Trim() }
    elseif ($line -match '^FakeSmtp__SmtpPort=(\d+)') { $current.SmtpPort = [int]$Matches[1] }
    elseif ($line -match '^FakeSmtp__MaxMessages=(\d+)') { $current.MaxMessages = [int]$Matches[1] }
    elseif ($line -match '^Urls=.*:(\d+)/?\s*$') { $current.WebPort = [int]$Matches[1] }
  }
}
if (-not $PSBoundParameters.ContainsKey('SmtpPort')) { $SmtpPort = $current.SmtpPort }
if (-not $PSBoundParameters.ContainsKey('WebPort')) { $WebPort = $current.WebPort }
if (-not $PSBoundParameters.ContainsKey('MaxMessages')) { $MaxMessages = $current.MaxMessages }

# --- Where to store received emails ---------------------------------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('MailFolder')) {
  $MailFolder = $current.MailFolder
  if ($interactive) {
    $answer = Read-Host "Where should received emails be stored? Press Enter for [$($current.MailFolder)]"
    if ($answer.Trim()) { $MailFolder = $answer.Trim().Trim('"') }
  }
}
try { $MailFolder = Resolve-FullPath $MailFolder (Get-Location).Path }
catch { throw "'$MailFolder' is not a valid folder path." }
$moveFrom = $null
if ((Test-Path $current.MailFolder) -and ($current.MailFolder.TrimEnd('\') -ne $MailFolder.TrimEnd('\'))) {
  $stored = @(Get-ChildItem $current.MailFolder -Filter *.eml -File)
  if ($stored.Count) {
    $move = $true
    if ($interactive) {
      $answer = Read-Host "Move $($stored.Count) stored message(s) from $($current.MailFolder) to $MailFolder? [Y/n]"
      $move = $answer.Trim() -notmatch '^(n|no)$'
    }
    if ($move) { $moveFrom = $current.MailFolder }
  }
}

# --- Replace an existing service (stop it first so files and ports are free) --------------------------------
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

if (-not $SkipPublish) {
  Write-Host "Publishing to $InstallDir"
  & dotnet publish $project -c Release -o $InstallDir --nologo
  if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }
}
$exe = Join-Path $InstallDir 'FakeSmtp.exe'
if (-not (Test-Path $exe)) { throw "$exe not found; publish first or drop -SkipPublish." }

# --- Write the settings into the installed appsettings.json ---------------------------------------------------
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$config.FakeSmtp.MailFolder = $MailFolder
$config.FakeSmtp.SmtpPort = $SmtpPort
$config.FakeSmtp.MaxMessages = $MaxMessages
$config.Urls = "http://127.0.0.1:$WebPort"
[IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))

# --- Folders, moved mail and permissions ----------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $MailFolder, $LogFolder | Out-Null
if ($moveFrom) {
  $moved = 0
  foreach ($eml in Get-ChildItem $moveFrom -Filter *.eml -File) {
    foreach ($file in $eml.FullName, [IO.Path]::ChangeExtension($eml.FullName, '.json')) {
      if (Test-Path $file) { Move-Item $file $MailFolder -Force }
    }
    $moved++
  }
  Write-Host "Moved $moved message(s) to $MailFolder"
}
& icacls $InstallDir /grant "${Account}:(OI)(CI)RX" /T /Q | Out-Null
& icacls $MailFolder /grant "${Account}:(OI)(CI)M" /T /Q | Out-Null
& icacls $LogFolder /grant "${Account}:(OI)(CI)M" /T /Q | Out-Null

# --- Register and start the service ---------------------------------------------------------------------------
Write-Host "Installing service $ServiceName"
Invoke-Nssm install $ServiceName $exe
Invoke-Nssm set $ServiceName AppDirectory $InstallDir
Invoke-Nssm set $ServiceName DisplayName 'Fake SMTP (local dev email catcher)'
Invoke-Nssm set $ServiceName Description "Stores all mail sent to 127.0.0.1:$SmtpPort; viewer at http://127.0.0.1:$WebPort. Nothing is delivered."
Invoke-Nssm set $ServiceName Start SERVICE_DELAYED_AUTO_START
Invoke-Nssm set $ServiceName ObjectName $Account
Invoke-Nssm set $ServiceName AppStdout (Join-Path $LogFolder 'service.log')
Invoke-Nssm set $ServiceName AppStderr (Join-Path $LogFolder 'service.log')
Invoke-Nssm set $ServiceName AppRotateFiles 1
Invoke-Nssm set $ServiceName AppRotateBytes 10485760
Invoke-Nssm set $ServiceName AppExit Default Restart
Invoke-Nssm set $ServiceName AppRestartDelay 5000

Start-Service $ServiceName
Start-Sleep -Seconds 3
Get-Service $ServiceName | Format-Table Status, StartType, Name -AutoSize
Write-Host "SMTP:     127.0.0.1:$SmtpPort"
Write-Host "Viewer:   http://127.0.0.1:$WebPort"
Write-Host "Mail:     $MailFolder"
Write-Host "Logs:     $LogFolder"
Write-Host "Settings: $configPath (edit, then Restart-Service $ServiceName)"
