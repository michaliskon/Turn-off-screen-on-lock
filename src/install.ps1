# Bootstrap installer - downloads the latest release and runs the installer.
# Usage: irm https://github.com/michaliskon/Turn-off-screen-on-lock/releases/latest/download/install.ps1 | iex

$ErrorActionPreference = 'Stop'

$repo = "michaliskon/Turn-off-screen-on-lock"
$installDir = "Turn-off-screen-on-lock"

$tag = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
$zipName = "Turn-off-screen-on-lock-$tag.zip"
$baseUrl = "https://github.com/$repo/releases/download/$tag"

Write-Host "Downloading $tag... " -ForegroundColor DarkCyan -NoNewline
Invoke-WebRequest "$baseUrl/$zipName" -OutFile $zipName
Invoke-WebRequest "$baseUrl/checksums-sha256.txt" -OutFile "checksums-sha256.txt"
Write-Host "OK" -ForegroundColor Green

Write-Host "Verifying checksum... " -ForegroundColor DarkCyan -NoNewline
$expectedLine = (Get-Content "checksums-sha256.txt" | Select-String $zipName).ToString()
$expectedHash = ($expectedLine -split '\s+')[0]
$actualHash = (Get-FileHash $zipName -Algorithm SHA256).Hash.ToLower()
Remove-Item "checksums-sha256.txt"

if ($actualHash -ne $expectedHash) {
    Remove-Item $zipName
    throw "Checksum verification failed. Expected: $expectedHash, Got: $actualHash"
}
Write-Host "PASS" -ForegroundColor Green

Write-Host "Extracting to .\$installDir\" -ForegroundColor DarkCyan
Expand-Archive $zipName -DestinationPath $installDir -Force
Remove-Item $zipName

Write-Host "Running installer..." -ForegroundColor DarkCyan
& ".\$installDir\installer.ps1"
