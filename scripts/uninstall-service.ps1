<#
.SYNOPSIS
  Stops and removes the Fake SMTP Windows service. Stored mail and logs are left in place.
#>
[CmdletBinding()]
param(
  [string]$NssmPath    = 'C:\Tools\nssm.exe',
  [string]$ServiceName = 'FakeSmtp'
)
$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script from an elevated (Administrator) PowerShell.' }

if (-not (Get-Service $ServiceName -ErrorAction SilentlyContinue)) { Write-Host "Service $ServiceName is not installed."; return }

Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
if (Test-Path $NssmPath) { & $NssmPath remove $ServiceName confirm } else { & sc.exe delete $ServiceName }
if ($LASTEXITCODE -ne 0) { throw "Removing $ServiceName failed ($LASTEXITCODE)" }
Write-Host "Removed service $ServiceName."
