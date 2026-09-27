#Requires -Version 5.1
<#
  Homework tracker - one click deploy to GitHub Pages.

  Usage:
      powershell -ExecutionPolicy Bypass -File .\deploy.ps1
      powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -RepoName my-repo

  Requires: git, GitHub CLI (gh) and a previous successful "gh auth login".
  This file is intentionally ASCII-only: Windows PowerShell 5.1 may misread
  non-ASCII characters in BOM-less .ps1 files.
#>
[CmdletBinding()]
param(
  [string]$Owner = 'X3San',
  [string]$RepoName = 'homework-tracker',
  [string]$Branch = 'main'
)

# Keep 'Continue': native tools (git/gh) write progress and hints to stderr, and
# with 'Stop' PowerShell would abort the script on those harmless messages.
$ErrorActionPreference = 'Continue'

function Write-Step([string]$m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Note([string]$m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Fail([string]$m) {
  Write-Host ''
  Write-Host "ERROR: $m" -ForegroundColor Red
  exit 1
}

function Find-Gh {
  # Prefer PATH, then the usual install locations, then a WinGet package scan.
  $cmd = Get-Command gh -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @(
    (Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'GitHub CLI\gh.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\gh.exe'),
    (Join-Path $env:USERPROFILE 'scoop\shims\gh.exe')
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  }
  $roots = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
    (Join-Path $env:ProgramFiles 'WinGet\Packages')
  )
  foreach ($r in $roots) {
    if (Test-Path -LiteralPath $r) {
      $hit = Get-ChildItem -LiteralPath $r -Filter 'gh.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($hit) { return $hit.FullName }
    }
  }
  return $null
}

Set-Location -LiteralPath $PSScriptRoot

if (-not (Test-Path -LiteralPath '.\index.html')) {
  Fail "index.html was not found next to this script. Put deploy.ps1 inside the project folder."
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Fail "git not found. Install it with: winget install --id Git.Git -e --source winget"
}

$ghPath = Find-Gh
if (-not $ghPath) {
  Fail "GitHub CLI (gh) not found. Install it with: winget install --id GitHub.cli -e --source winget"
}
# gh is often missing from an already-running app's PATH, and git's credential
# helper calls gh by name, so put its folder on PATH for this session.
$ghDir = Split-Path -Parent $ghPath
if (($env:PATH -split ';') -notcontains $ghDir) { $env:PATH = "$ghDir;$env:PATH" }
Write-Note "gh: $ghPath"

Write-Step "Checking GitHub login"
$authOut = (& gh auth status 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
  Write-Host $authOut
  Fail "Not logged in to GitHub. Run:  gh auth login   (GitHub.com > HTTPS > Login with a web browser)"
}
Write-Note "logged in"

$full = "$Owner/$RepoName"

Write-Step "Preparing local git repository"
if (-not (Test-Path -LiteralPath '.\.git')) {
  & git init --quiet 2>&1 | Out-Null
  & git symbolic-ref HEAD "refs/heads/$Branch" 2>&1 | Out-Null
  Write-Note "git init done"
} else {
  Write-Note ".git already exists, reusing it"
}

$userName = (& git config --get user.name 2>$null)
if (-not $userName) {
  & git config user.name $Owner
  Write-Note "set local git user.name = $Owner"
}
$userEmail = (& git config --get user.email 2>$null)
if (-not $userEmail) {
  & git config user.email "$Owner@users.noreply.github.com"
  Write-Note "set local git user.email"
}

# Let git authenticate through the GitHub CLI login, without any prompt.
& git config --local "credential.https://github.com.helper" "!`"$($ghPath -replace '\\','/')`" auth git-credential" 2>$null | Out-Null

Write-Step "Committing files"
& git add -A
& git commit -m "init: homework tracker web app" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Note "nothing new to commit (or commit skipped)" }
& git branch -M $Branch 2>$null | Out-Null
Write-Note "branch: $Branch"

Write-Step "Creating or reusing GitHub repository $full"
& gh repo view $full 2>$null | Out-Null
$repoExists = ($LASTEXITCODE -eq 0)

if (-not $repoExists) {
  & gh repo create $full --public --description "Homework and submission tracker (single-file web app)" --disable-wiki --source . --remote origin --push
  if ($LASTEXITCODE -ne 0) { Fail "gh repo create failed. See the message above." }
  Write-Note "created and pushed"
} else {
  Write-Note "repository already exists, pushing to it"
  & git remote get-url origin 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { & git remote add origin "https://github.com/$full.git" }
  & git push -u origin $Branch
  if ($LASTEXITCODE -ne 0) {
    Fail "git push failed. If the remote already has unrelated history, push manually with: git push -u origin $Branch --force"
  }
}

Write-Step "Enabling GitHub Pages (branch: $Branch, folder: /)"
$pageBody = '{"source":{"branch":"' + $Branch + '","path":"/"}}'
$pageBody | & gh api -X POST "repos/$full/pages" --input - 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  $pageBody | & gh api -X PUT "repos/$full/pages" --input - 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Note "Could not turn on Pages automatically."
    Write-Note "Do it by hand: repository > Settings > Pages > Source: Deploy from a branch > $Branch > / (root) > Save"
  } else {
    Write-Note "Pages settings updated"
  }
} else {
  Write-Note "Pages enabled"
}

$htmlUrl = $null
$info = (& gh api "repos/$full/pages" 2>$null)
if ($info) {
  try { $htmlUrl = ($info | ConvertFrom-Json).html_url } catch { $htmlUrl = $null }
}
if (-not $htmlUrl) { $htmlUrl = "https://$Owner.github.io/$RepoName/" }

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host "Repository : https://github.com/$full"
Write-Host "Web page   : $htmlUrl"
Write-Note "The first build takes about a minute. A 404 right after deploying is normal."
Write-Note "On your phone: open the link, then use Add to Home Screen."
