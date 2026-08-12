[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string] $Version,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $InstallerPath
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

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI is required. Install it with: winget install GitHub.cli'
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is required. Install it with: winget install Git.Git'
}

Invoke-CheckedCommand gh auth status

$ResolvedInstaller = (Resolve-Path -LiteralPath $InstallerPath).Path
$Installer = Get-Item -LiteralPath $ResolvedInstaller
$AllowedExtensions = @('.msix', '.msixbundle', '.msi', '.exe')
if ($Installer.Extension.ToLowerInvariant() -notin $AllowedExtensions) {
    throw "Expected a Windows installer ($($AllowedExtensions -join ', ')), received $($Installer.Extension)"
}

$Signature = Get-AuthenticodeSignature -LiteralPath $ResolvedInstaller
if ($Signature.Status -ne 'Valid') {
    throw "The Windows installer does not have a valid Authenticode signature: $($Signature.Status)"
}

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

    $ChecksumPath = "$ResolvedInstaller.sha256"
    $Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ResolvedInstaller).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $ChecksumPath -NoNewline -Encoding utf8 `
        -Value "$Hash  $($Installer.Name)`n"

    foreach ($Asset in @($Installer.Name, (Split-Path -Leaf $ChecksumPath))) {
        if ($AssetNames -contains $Asset) {
            throw "GitHub release $Tag already contains $Asset; refusing to overwrite it."
        }
    }

    Invoke-CheckedCommand gh release upload $Tag $ResolvedInstaller $ChecksumPath
    Write-Host "Published $($Installer.Name) and its checksum to GitHub release $Tag."
}
finally {
    Pop-Location
}
