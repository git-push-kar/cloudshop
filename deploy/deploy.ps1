<#
.SYNOPSIS
Copies the CloudShop project to one EC2 instance, rebuilds the Docker image and
replaces the running container.

.DESCRIPTION
Run from the project root (or call the script by path). The script:
  1. Creates the remote project directory.
  2. Copies app/, requirements-api.txt, Dockerfile and .dockerignore with scp.
  3. Builds the image on the instance.
  4. Replaces the named container and checks /health.

The EC2 instance must already have Docker installed and the security group must
allow SSH and the API port from your current public IP.

.PARAMETER KeyPath
Path to the EC2 private key (.pem).

.PARAMETER EC2Host
Public IPv4 address or public DNS name of the instance.

.PARAMETER RemoteUser
SSH user on Amazon Linux. Default: ec2-user.

.PARAMETER RemoteDir
Project directory relative to the remote user's home. Default: cloudshop.

.PARAMETER ImageTag
Docker image tag to build and run. Default: cloudshop-api:1.0.

.PARAMETER ContainerName
Container name to replace. Default: cloudshop.

.PARAMETER Port
Host port published for the API. Default: 8000.

.EXAMPLE
.\deploy\deploy.ps1 -KeyPath "C:\keys\cloudshop-key.pem" -EC2Host "3.110.1.2"

.EXAMPLE
.\deploy\deploy.ps1 -KeyPath "C:\keys\cloudshop-key.pem" -EC2Host "ec2-3-110-1-2.ap-south-1.compute.amazonaws.com" -Port 8000
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$KeyPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$EC2Host,

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$RemoteUser = "ec2-user",

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$RemoteDir = "cloudshop",

    [ValidatePattern('^[a-z0-9][a-z0-9._/-]*$')]
    [string]$ImageTag = "cloudshop-api:1.0",

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
    [string]$ContainerName = "cloudshop",

    [ValidateRange(1, 65535)]
    [int]$Port = 8000
)

$ErrorActionPreference = "Stop"

foreach ($commandName in @("ssh", "scp")) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "OpenSSH command '$commandName' was not found. Install the Windows OpenSSH Client."
    }
}

if (-not (Test-Path -LiteralPath $KeyPath)) {
    throw "Private key not found: $KeyPath"
}
$KeyPath = (Resolve-Path -LiteralPath $KeyPath).Path

$RepoRoot = Split-Path -Parent $PSScriptRoot
$items = @(
    (Join-Path $RepoRoot "app"),
    (Join-Path $RepoRoot "requirements-api.txt"),
    (Join-Path $RepoRoot "Dockerfile"),
    (Join-Path $RepoRoot ".dockerignore")
)

foreach ($item in $items) {
    if (-not (Test-Path -LiteralPath $item)) {
        throw "Required deployment file not found: $item"
    }
}

$sshArgs = @(
    "-i", $KeyPath,
    "-o", "ConnectTimeout=15",
    "$RemoteUser@$EC2Host"
)
$scpArgs = @(
    "-i", $KeyPath,
    "-o", "ConnectTimeout=15",
    "-r"
) + $items + @("${RemoteUser}@${EC2Host}:${RemoteDir}/")

Write-Host "Creating remote directory ~/$RemoteDir ..."
& ssh @sshArgs "mkdir -p '$RemoteDir'"
if ($LASTEXITCODE -ne 0) {
    throw "Could not create the remote directory. Check SSH access and the key."
}

Write-Host "Copying app, Dockerfile and API requirements ..."
& scp @scpArgs
if ($LASTEXITCODE -ne 0) {
    throw "scp failed. Check SSH access, the key and the remote directory."
}

$remoteScript = @(
    "set -e",
    "cd '$RemoteDir'",
    "if ! docker info >/dev/null 2>&1; then",
    "  echo 'Docker is not accessible for $RemoteUser. Re-login after usermod or fix permissions.' >&2",
    "  exit 1",
    "fi",
    "docker build -t '$ImageTag' .",
    "docker rm -f '$ContainerName' >/dev/null 2>&1 || true",
    "docker run -d --name '$ContainerName' --restart unless-stopped -p ${Port}:8000 '$ImageTag'",
    "docker ps --filter 'name=$ContainerName' --format '{{.Status}}'"
) -join "`n"

Write-Host "Building image and replacing container '$ContainerName' ..."
& ssh @sshArgs $remoteScript
if ($LASTEXITCODE -ne 0) {
    throw "Remote build or container restart failed. Check the SSH output above."
}

$healthUrl = "http://${EC2Host}:${Port}/health"
Write-Host "Checking $healthUrl ..."
$healthy = $false
for ($attempt = 1; $attempt -le 15; $attempt++) {
    try {
        $response = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 3
        if ($response.status -eq "ok") {
            $healthy = $true
            break
        }
    }
    catch {
        Start-Sleep -Seconds 2
    }
}

if ($healthy) {
    Write-Host "Deployment complete. Health check passed."
}
else {
    Write-Warning "Container restarted, but the health check did not pass. Check the security group, container logs and status."
}
