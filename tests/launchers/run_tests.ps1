# Runs only the maintained controller and launcher regressions with Windows PowerShell.
# The checks keep file/power substitutes in memory and generate no temporary artifacts.
[CmdletBinding()]
param([string]$source_root)

$ErrorActionPreference = 'Stop'
if (-not $source_root) { $source_root = Join-Path $PSScriptRoot '..\..\src' }
$source_root = (Resolve-Path -LiteralPath $source_root -ErrorAction Stop).Path
& (Join-Path $PSScriptRoot '..\LockTimeoutController.Tests.ps1') -source_root $source_root
& (Join-Path $PSScriptRoot 'RunHidden.Tests.ps1') -source_root $source_root
Write-Output 'All controller and launcher regression checks passed.'
