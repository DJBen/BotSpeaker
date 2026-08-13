# Builds, packages, and publishes the Windows app to the shared versioned GitHub
# release — the Windows counterpart of release-macos.sh.
#
# Produces a self-contained single-file BotSpeaker.exe (no .NET install needed),
# zips it with a SHA-256 checksum into dist/, and uploads both to the release,
# creating the tag/release if this platform gets there first.
#
# Signing: pass -CertificateThumbprint to Authenticode-sign the exe with signtool
# before packaging. Without a certificate, pass -AllowUnsigned to make shipping an
# unsigned build an explicit choice rather than a silent default.
#
#   .\scripts\publish-windows-release.ps1 -Version 0.2.0 -AllowUnsigned
#   .\scripts\publish-windows-release.ps1 -Version 0.2.0 -CertificateThumbprint <sha1>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string] $Version,

    [string] $CertificateThumbprint,

    [switch] $AllowUnsigned
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE"
    }
}

foreach ($Tool in @('gh', 'git')) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "$Tool is required. Install it with: winget install $(if ($Tool -eq 'gh') { 'GitHub.cli' } else { 'Git.Git' })"
    }
}

# Prefer a user-local .NET install (DOTNET_ROOT) over PATH, matching dev setups
# where no machine-wide SDK exists.
$Dotnet = if ($env:DOTNET_ROOT -and (Test-Path "$env:DOTNET_ROOT\dotnet.exe")) {
    "$env:DOTNET_ROOT\dotnet.exe"
} elseif (Get-Command dotnet -ErrorAction SilentlyContinue) {
    (Get-Command dotnet).Source
} else {
    throw 'The .NET SDK is required. Install it from https://dotnet.microsoft.com/download or set DOTNET_ROOT.'
}

if (-not $CertificateThumbprint -and -not $AllowUnsigned) {
    throw 'No -CertificateThumbprint given. Pass -AllowUnsigned to explicitly publish an unsigned build.'
}

Invoke-CheckedCommand gh auth status

$RepoRoot = (& git rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or -not $RepoRoot) {
    throw 'Run this script from a BotSpeaker Git checkout.'
}

Push-Location $RepoRoot
try {
    $WorkingTreeChanges = @(& git status --porcelain)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect the Git working tree.'
    }
    if ($WorkingTreeChanges.Count -gt 0) {
        throw 'Commit all release source changes before publishing to GitHub.'
    }

    $ProjectFile = Join-Path $RepoRoot 'Windows\BotSpeaker\BotSpeaker.csproj'
    $ProjectVersion = ([xml](Get-Content -LiteralPath $ProjectFile)).Project.PropertyGroup.Version
    if ($ProjectVersion -ne $Version) {
        throw "BotSpeaker.csproj declares version $ProjectVersion, but you are releasing $Version. Update <Version> and commit first."
    }

    $DistDirectory = Join-Path $RepoRoot 'dist'
    $PublishDirectory = Join-Path $DistDirectory 'windows-publish'
    if (Test-Path $PublishDirectory) {
        Remove-Item -Recurse -Force $PublishDirectory
    }

    Invoke-CheckedCommand $Dotnet publish (Join-Path $RepoRoot 'Windows\BotSpeaker') `
        -c Release -r win-x64 --self-contained true `
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
        -o $PublishDirectory -nologo

    $ExePath = Join-Path $PublishDirectory 'BotSpeaker.exe'
    if (-not (Test-Path -LiteralPath $ExePath)) {
        throw "Publish did not produce $ExePath"
    }

    if ($CertificateThumbprint) {
        if (-not (Get-Command signtool -ErrorAction SilentlyContinue)) {
            throw 'signtool is required for signing. Install the Windows SDK or add signtool to PATH.'
        }
        Invoke-CheckedCommand signtool sign /sha1 $CertificateThumbprint /fd SHA256 `
            /tr http://timestamp.digicert.com /td SHA256 $ExePath
        $Signature = Get-AuthenticodeSignature -LiteralPath $ExePath
        if ($Signature.Status -ne 'Valid') {
            throw "Signing failed; Authenticode status is $($Signature.Status)."
        }
    }
    else {
        Write-Warning 'Publishing an UNSIGNED build; Windows SmartScreen will warn users who run it.'
    }

    $ZipName = "BotSpeaker-Windows-x64-$Version.zip"
    $ZipPath = Join-Path $DistDirectory $ZipName
    Compress-Archive -LiteralPath $ExePath -DestinationPath $ZipPath -Force

    $ChecksumPath = "$ZipPath.sha256"
    $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ZipPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $ChecksumPath -NoNewline -Encoding utf8 -Value "$Hash  $ZipName`n"

    $Tag = $Version
    $ReleaseExists = $true
    & gh release view $Tag *> $null
    if ($LASTEXITCODE -ne 0) {
        $ReleaseExists = $false
    }

    if (-not $ReleaseExists) {
        & git ls-remote --exit-code --tags origin "refs/tags/$Tag" *> $null
        if ($LASTEXITCODE -ne 0) {
            & git show-ref --verify --quiet "refs/tags/$Tag"
            if ($LASTEXITCODE -ne 0) {
                Invoke-CheckedCommand git tag -a $Tag -m "BotSpeaker $Version"
            }
            Invoke-CheckedCommand git push origin $Tag
        }

        Invoke-CheckedCommand gh release create $Tag `
            --verify-tag `
            --title "BotSpeaker $Version" `
            --notes 'Cross-platform BotSpeaker release. See the attached assets for macOS and Windows downloads.'
    }

    & git fetch --quiet origin "refs/tags/$Tag`:refs/tags/$Tag" 2> $null
    $TagCommit = (& git rev-list -n 1 $Tag).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to resolve release tag $Tag"
    }
    $HeadCommit = (& git rev-parse HEAD).Trim()
    if ($TagCommit -ne $HeadCommit) {
        throw "$Tag points to $TagCommit, but this checkout is $HeadCommit. Check out the release tag before uploading assets."
    }

    $AssetNames = @(& gh release view $Tag --json assets --jq '.assets[].name')
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect GitHub release $Tag"
    }

    foreach ($Asset in @($ZipName, (Split-Path -Leaf $ChecksumPath))) {
        if ($AssetNames -contains $Asset) {
            throw "GitHub release $Tag already contains $Asset; refusing to overwrite it."
        }
    }

    Invoke-CheckedCommand gh release upload $Tag $ZipPath $ChecksumPath
    Write-Host "Published $ZipName and its checksum to GitHub release $Tag."
}
finally {
    Pop-Location
}
