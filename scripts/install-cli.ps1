# Installs or updates the botspeaker-cli command on Windows — the counterpart
# of scripts/install-cli.sh for macOS. (The command is `botspeaker-cli` rather
# than `botspeaker` because BotSpeaker.exe, the app, would be the same file
# name on Windows.)
#
#   irm https://raw.githubusercontent.com/DJBen/BotSpeaker/main/scripts/install-cli.ps1 | iex
#   .\scripts\install-cli.ps1                    # latest GitHub release, into %LOCALAPPDATA%\Programs\BotSpeaker
#   .\scripts\install-cli.ps1 -Version 0.5.0     # a specific release
#   .\scripts\install-cli.ps1 -Source            # build Windows/BotSpeakerCli from this checkout instead of downloading
#   .\scripts\install-cli.ps1 -Source -IncludeApp  # also build and install BotSpeaker.exe beside it
#   .\scripts\install-cli.ps1 -Destination D:\bin
#
# The destination directory is added to the user PATH when it is not already
# there. An existing botspeaker-cli.exe in the destination is replaced,
# whatever its version. Keep BotSpeaker.exe (the app) in the same directory,
# or set BOTSPEAKER_APP, so the CLI can launch the app when it is not running;
# it also remembers the last app it talked to.

[CmdletBinding()]
param(
    [string] $Version = '',
    [switch] $Source,
    [switch] $IncludeApp,
    [string] $Destination = ''
)

$ErrorActionPreference = 'Stop'
$Repository = 'DJBen/BotSpeaker'
$Asset = 'botspeaker-cli-windows-x64.zip'
$ExeName = 'botspeaker-cli.exe'

function Set-CliPath([string] $Directory) {
    # Prepend, and update this shell too: appending lets an older CLI win.
    foreach ($Scope in @('User', 'Process')) {
        $Existing = [Environment]::GetEnvironmentVariable('Path', $Scope)
        $Others = @($Existing -split ';' | Where-Object {
            $_ -and [Environment]::ExpandEnvironmentVariables($_.Trim().Trim('"')).TrimEnd('\') -ine $Directory.TrimEnd('\')
        })
        [Environment]::SetEnvironmentVariable('Path', ((@($Directory) + $Others) -join ';'), $Scope)
    }
    Write-Host "CLI directory is first on your user PATH and this terminal's PATH: $Directory"
    Write-Host "Restart other terminals to refresh PATH. Use Get-Command botspeaker-cli -All to check for older copies."
}

# Prefer the bundled CLI after installing the auto-updating app. Do not copy it
# out of the managed directory: that would leave a stale CLI on PATH after updates.
$ManagedDirectory = Join-Path $env:LOCALAPPDATA 'BotSpeaker.Windows\current'
if (-not $Source -and -not $Version -and -not $Destination -and
    (Test-Path -LiteralPath (Join-Path $ManagedDirectory $ExeName))) {
    Set-CliPath $ManagedDirectory
    Write-Host "Using the auto-updating CLI in $ManagedDirectory."
    return
}

if (-not $Destination) {
    $Destination = Join-Path $env:LOCALAPPDATA 'Programs\BotSpeaker'
}
$Destination = [IO.Path]::GetFullPath($Destination)
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$Target = Join-Path $Destination $ExeName
$Staging = Join-Path ([IO.Path]::GetTempPath()) ("botspeaker-cli-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Staging | Out-Null

try {
    if ($Source) {
        $RepoRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
        $Project = Join-Path $RepoRoot 'Windows\BotSpeakerCli'
        if (-not (Test-Path (Join-Path $Project 'BotSpeakerCli.csproj'))) {
            throw "-Source needs a BotSpeaker checkout; $Project was not found."
        }
        $Dotnet = if ($env:DOTNET_ROOT -and (Test-Path "$env:DOTNET_ROOT\dotnet.exe")) { "$env:DOTNET_ROOT\dotnet.exe" }
                  elseif (Get-Command dotnet -ErrorAction SilentlyContinue) { (Get-Command dotnet).Source }
                  else { throw 'The .NET SDK is required to build from source. Install it from https://dotnet.microsoft.com/download.' }
        Write-Host "Building $ExeName from $Project"
        & $Dotnet publish $Project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:PublishTrimmed=false -o $Staging -nologo -v q
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }
        if ($IncludeApp) {
            $AppProject = Join-Path $RepoRoot 'Windows\BotSpeaker'
            $AppStaging = Join-Path $Staging 'app'
            $AppTarget = Join-Path $Destination 'BotSpeaker.exe'
            Write-Host "Building BotSpeaker.exe from $AppProject"
            Get-Process BotSpeaker -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $AppTarget } | ForEach-Object {
                Write-Host "Stopping the installed BotSpeaker (pid $($_.Id)) so it can be replaced"
                $_.Kill(); $_.WaitForExit()
            }
            & $Dotnet publish $AppProject -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $AppStaging -nologo -v q
            if ($LASTEXITCODE -ne 0) { throw "dotnet publish (app) failed with exit code $LASTEXITCODE" }
            Copy-Item -LiteralPath (Join-Path $AppStaging 'BotSpeaker.exe') -Destination $AppTarget -Force
            Write-Host "Installed BotSpeaker.exe to $Destination"
        }
    }
    else {
        $Tag = $Version.TrimStart('v')
        if (-not $Tag) {
            $Latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers @{ 'User-Agent' = 'botspeaker-install' }
            $Tag = $Latest.tag_name
        }
        $Url = "https://github.com/$Repository/releases/download/$Tag/$Asset"
        $Zip = Join-Path $Staging $Asset
        Write-Host "Downloading $Url"
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Zip -UseBasicParsing
        }
        catch {
            throw "Release $Tag has no $Asset (older releases predate the Windows CLI). Run with -Source from a checkout instead."
        }
        $Checksum = (Invoke-WebRequest -Uri "$Url.sha256" -UseBasicParsing).Content
        if ($Checksum -is [byte[]]) { $Checksum = [Text.Encoding]::UTF8.GetString($Checksum) }
        $Expected = ($Checksum.Trim() -split '\s+')[0]
        if ($Expected -notmatch '^[a-fA-F0-9]{64}$' -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $Zip).Hash -ine $Expected) {
            throw 'CLI download failed SHA-256 verification. The installed CLI was not changed.'
        }
        Expand-Archive -LiteralPath $Zip -DestinationPath $Staging -Force
    }

    $Built = Get-ChildItem -Path $Staging -Filter $ExeName -Recurse | Select-Object -First 1
    if (-not $Built) { throw "No $ExeName was produced." }
    Copy-Item -LiteralPath $Built.FullName -Destination $Target -Force
    $Installed = (& $Target --version 2>$null)
    Write-Host "Installed botspeaker-cli $Installed to $Target"

    Set-CliPath $Destination
}
finally {
    Remove-Item -Recurse -Force $Staging -ErrorAction SilentlyContinue
}
