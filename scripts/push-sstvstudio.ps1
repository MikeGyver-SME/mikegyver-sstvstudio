<#
.SYNOPSIS
  Pushes the SSTV Studio source to GitHub and tags a release (which starts the
  TestFlight build workflow).

.DESCRIPTION
  1. Uses the extracted sstv-studio-ios-v1.0.4 folder as the source of truth.
  2. Clones MikeGyver-SME/mikegyver-sstvstudio if needed (else pulls main).
  3. Copies the source in, commits, pushes.
  4. Creates and pushes the version tag -> the "Build and upload SSTV Studio to
     TestFlight" workflow starts automatically on the tag push.

  The tree already contains .github\workflows\testflight.yml, the
  fixed Info.plist, and the AppIcon set - nothing to drop in first.

.PARAMETER SourceDir
  The extracted source folder. Defaults to E:\Downloads when it exists, else your shell Downloads folder\sstv-studio-ios-v1.0.4
  (resolved via the Windows shell, so relocated Downloads folders work).

.PARAMETER RepoDir
  Local clone location. Defaults to source\repos\mikegyver-sstvstudio under your
  user profile.

.PARAMETER Tag
  Version tag to create and push, e.g. v1.0.4. The workflow runs on tags
  matching v*.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\push-sstvstudio.ps1
  # uses defaults, tags v1.0.4

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\push-sstvstudio.ps1 -Tag v1.0.5
#>
param(
    [string]$SourceDir = (Join-Path (& { if (Test-Path 'E:\Downloads') { 'E:\Downloads' } else { try { (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch { "$env:USERPROFILE\Downloads" } } }) 'sstv-studio-ios-v1.0.4'),
    [string]$RepoDir   = (Join-Path $env:USERPROFILE 'source\repos\mikegyver-sstvstudio'),
    [string]$Tag       = 'v1.0.4'
)

$ErrorActionPreference = 'Stop'
$RepoSlug = 'MikeGyver-SME/mikegyver-sstvstudio'

if (-not (Test-Path $SourceDir)) {
    throw "Source folder not found: $SourceDir`nExtract sstv-studio-ios-v1.0.4.zip first."
}

# --- 1. Clone or update ------------------------------------------------------
if (-not (Test-Path (Join-Path $RepoDir '.git'))) {
    Write-Host "Cloning $RepoSlug ..." -ForegroundColor Cyan
    git clone "https://github.com/$RepoSlug.git" $RepoDir
}
Set-Location $RepoDir
# NOTE: never probe git with a command that can fail here. With
# $ErrorActionPreference='Stop', a failing git probe's stderr becomes a
# terminating error. `git status` is safe even on empty repos.
$statusOut = git status 2>&1 | Out-String
if ($statusOut -match 'No commits yet') {
    # Fresh empty repo: start main locally; the push below creates it on GitHub.
    git checkout -qb main
} else {
    git checkout --quiet main
    git pull --ff-only
}

# --- 2. Copy source in (excluding .git) --------------------------------------
Write-Host "Copying source from $SourceDir ..." -ForegroundColor Cyan
Get-ChildItem -Path $RepoDir -Force -Exclude '.git' | Remove-Item -Recurse -Force
Copy-Item -Path (Join-Path $SourceDir '*') -Destination $RepoDir -Recurse -Force

# --- 3. Commit + push (tag push starts the Actions run) ----------------------
git add -A
$status = git status --porcelain
if ($status) {
    git commit -m "SSTV Studio $Tag"
    Write-Host "Pushing to main ..." -ForegroundColor Cyan
    git push origin main
} else {
    Write-Host "No changes to commit." -ForegroundColor Yellow
}

# `git tag --list` never fails: empty output when the tag is absent.
$existingTag = git tag --list $Tag
if ($existingTag) {
    Write-Host "Tag $Tag already exists locally." -ForegroundColor Yellow
} else {
    git tag $Tag
}
Write-Host "Pushing tag $Tag (this starts the TestFlight build) ..." -ForegroundColor Cyan
git push origin $Tag

Write-Host ""
Write-Host "Done. Watch the build at:" -ForegroundColor Green
Write-Host "  https://github.com/$RepoSlug/actions"
Write-Host "When it finishes, the build lands in App Store Connect -> TestFlight."
