<#
.SYNOPSIS
    Persistent-volume host configuration script for 3ds Max on AWS Deadline Cloud.

.DESCRIPTION
    Installs 3ds Max and any plugins you configure onto a Service-Managed Fleet.
    When a persistent volume is attached (DEADLINE_PERSISTENT_MOUNT), software is
    installed there once and subsequent worker boots re-create junctions in seconds
    instead of re-downloading and re-installing (saves 10-15 min per cold start).

    Without a persistent volume the script falls back to a normal install on C:\.

    Plugins are configured as entries in the $PLUGINS array below. Each entry needs
    a Name, S3 URI, and the silent-install arguments for that installer. Copy the
    install block from the reference scripts linked below for the correct flags.

.NOTES
    Plugin installation references (for silent-install flags and post-install config):
    V-Ray:        https://github.com/aws-deadline/deadline-cloud-samples/blob/mainline/host_configuration_scripts/3dsmax/3dsmax-2025-and-vray.ps1
    Corona:       https://github.com/aws-deadline/deadline-cloud-samples/blob/mainline/host_configuration_scripts/3dsmax/3dsmax-2025-and-corona-13.ps1
    Pencil+ 4:    https://github.com/aws-deadline/deadline-cloud-samples/blob/mainline/host_configuration_scripts/3dsmax/3dsmax-2025-and-pencilplus-4.ps1
    tyFlow:       https://github.com/aws-deadline/deadline-cloud-samples/blob/mainline/host_configuration_scripts/3dsmax/3dsmax-2025-vray-and-tyflow.ps1
    AEC plugins:  https://github.com/aws-deadline/deadline-cloud-samples/blob/mainline/host_configuration_scripts/3dsmax/3dsmax-2025-vray-and-aec-plugins.ps1

    3ds Max zip creation guide:
    https://github.com/aws-deadline/deadline-cloud-samples/blob/mainline/host_configuration_scripts/3dsmax/README.md#creating-a-3ds-max-installer-archive-in-zip-format

    KNOWN ISSUE (3ds Max 2027 only): ADP "Failed to start" - see:
    https://github.com/aws-deadline/deadline-cloud-samples/blob/mainline/host_configuration_scripts/3dsmax/README.md#known-issue-autodesk-adp-failed-to-start-3ds-max-2027

    Requirements:
    - S3 bucket with the 3ds Max zip and any plugin installers
    - Fleet IAM role with s3:GetObject on that bucket
    - (Optional) A persistent volume attached to the fleet for cached installs
#>

$ErrorActionPreference = "Stop"
trap {
    Write-Host "ERROR: $($_.Exception.Message)"
    Write-Host $_.InvocationInfo.PositionMessage
    Write-Host $_.ScriptStackTrace
    exit 1
}

# ============================================================
# CONFIG - Replace TODO values with your S3 URIs and versions
# ============================================================

# TODO: 3ds Max installer zip (required)
$MAX_VERSION = "2025"
$3DS_MAX_INSTALLER_ZIP_S3_URI = "s3://your-bucket-name/path/to/3ds-Max-2025.zip"

# TODO: Plugins to install. Add entries for each plugin you need.
# Each entry: Name (display), S3URI, Args (silent-install flags).
# Set Type = "zip-to-plugins" for plugins that are just a zip extracted to the plugins dir.
# Leave this array empty if you only need base 3ds Max.
# See the reference links in .NOTES above for the correct Args per plugin.
$PLUGINS = @(
    # Example: Pencil+ 4 (Inno Setup - do NOT use /S, use /VERYSILENT)
    # @{ Name = "Pencil+ 4"; S3URI = "s3://your-bucket/setup_Pencil+_4.2.7_for_3dsMax_ntr.exe"; Args = @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-") }

    # Example: V-Ray (NSIS - do NOT rename the installer after download)
    # @{ Name = "V-Ray"; S3URI = "s3://your-bucket/vray_adv_62004_3dsmax2025.exe"; Args = @("/S") }

    # Example: Corona (Chaos installer)
    # @{ Name = "Corona 14"; S3URI = "s3://your-bucket/chaos-corona-14.exe"; Args = @("-gui=0", "-auto") }

    # Example: tyFlow (zip extracted to plugins directory)
    # @{ Name = "tyFlow"; S3URI = "s3://your-bucket/tyFlow.zip"; Args = @(); Type = "zip-to-plugins" }
)

# ============================================================
# END CONFIG
# ============================================================

$MAX_INSTALL_DIR = "C:\Program Files\Autodesk\3ds Max $MAX_VERSION"
$SETUP_DIR = "C:\3dsmax_setup"
$DOWNLOADS_DIR = "$SETUP_DIR\downloads"

# --- Persistent volume detection ---
$MOUNT_PATH = [Environment]::GetEnvironmentVariable("DEADLINE_PERSISTENT_MOUNT", "Machine")
if ($MOUNT_PATH) {
    Write-Host "Persistent volume detected: $MOUNT_PATH"
    $PERSISTENCE_ENABLED = $true
    $SW_PATH = "$MOUNT_PATH\Software"
    $INSTALL_MARKER = "$SW_PATH\.3dsmax-$MAX_VERSION-install-complete"
} else {
    Write-Host "No persistent volume - normal install (re-downloads on each boot)"
    $PERSISTENCE_ENABLED = $false
}

# --- Helper: download from S3 with error handling ---
function Download-FromS3 {
    param([string]$Uri, [string]$Destination)
    $file = Split-Path $Uri -Leaf
    $path = Join-Path $Destination $file
    if (Test-Path $path) {
        Write-Host "  Already downloaded: $file"
        return $path
    }
    Write-Host "  Downloading: $file"
    aws s3 cp --no-progress $Uri $path | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to download $Uri. Check the S3 URI and fleet IAM role." }
    return $path
}

# --- Helper: create junction ---
function New-JunctionIfNeeded {
    param([string]$Link, [string]$Target)
    if (Test-Path $Link) {
        $item = Get-Item $Link -Force
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-Host "  Junction exists: $Link"
            return
        }
        Remove-Item $Link -Recurse -Force
    }
    $parent = Split-Path $Link -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
    Write-Host "  Junction: $Link -> $Target"
}

# --- Helper: set environment variables ---
function Set-MaxEnvironment {
    [Environment]::SetEnvironmentVariable('Path', "$MAX_INSTALL_DIR;" + [Environment]::GetEnvironmentVariable('Path', 'Machine'), 'Machine')
    [Environment]::SetEnvironmentVariable('3DSMAX_EXECUTABLE', "$MAX_INSTALL_DIR\3dsmaxbatch.exe", 'Machine')
    [Environment]::SetEnvironmentVariable('MAXCMD_EXECUTABLE', "$MAX_INSTALL_DIR\3dsmaxcmd.exe", 'Machine')
    [Environment]::SetEnvironmentVariable('PYTHONPATH', "$MAX_INSTALL_DIR\Python;$MAX_INSTALL_DIR\Python\Scripts", 'Machine')
    [Environment]::SetEnvironmentVariable('Path', "$MAX_INSTALL_DIR\Python;$MAX_INSTALL_DIR\Python\Scripts;" + [Environment]::GetEnvironmentVariable('Path', 'Machine'), 'Machine')
}

# --- Warm-boot fast path (persistent volume, already installed) ---
if ($PERSISTENCE_ENABLED -and (Test-Path $INSTALL_MARKER)) {
    Write-Host "=== Warm boot: software already installed on persistent volume ==="
    New-JunctionIfNeeded -Link $MAX_INSTALL_DIR -Target "$SW_PATH\3dsMax$MAX_VERSION"
    Set-MaxEnvironment
    Write-Host "=== Warm boot complete ==="
    Exit 0
}

# --- Cold install ---
Write-Host "=== Cold install: downloading and installing software ==="

if ($PERSISTENCE_ENABLED) {
    New-JunctionIfNeeded -Link $MAX_INSTALL_DIR -Target "$SW_PATH\3dsMax$MAX_VERSION"
}

# Download and install 3ds Max
New-Item -ItemType Directory -Path $DOWNLOADS_DIR -Force | Out-Null
$maxZip = Download-FromS3 -Uri $3DS_MAX_INSTALLER_ZIP_S3_URI -Destination $DOWNLOADS_DIR

Write-Host "--- Installing 3ds Max $MAX_VERSION ---"
Expand-Archive $maxZip "$SETUP_DIR\max_installer" -Force
$setupExe = Get-ChildItem "$SETUP_DIR\max_installer" -Filter "Setup.exe" -Recurse | Select-Object -First 1 -ExpandProperty FullName
if (-not $setupExe) {
    throw "Setup.exe not found after extracting zip. Ensure the zip contains Setup.exe (can be in a subfolder)."
}
Write-Host "  Found: $setupExe"
Start-Process $setupExe -ArgumentList '-q' -Wait -PassThru

# Install plugins
foreach ($plugin in $PLUGINS) {
    if (-not $plugin.S3URI) { continue }
    Write-Host "--- Installing $($plugin.Name) ---"
    $installerPath = Download-FromS3 -Uri $plugin.S3URI -Destination $DOWNLOADS_DIR

    if ($plugin.Type -eq "zip-to-plugins") {
        Expand-Archive $installerPath "$MAX_INSTALL_DIR\plugins" -Force
    } else {
        Start-Process $installerPath -ArgumentList $plugin.Args -Wait -PassThru
    }
    Write-Host "  Done: $($plugin.Name)"
}

# Configure environment
Write-Host "--- Configuring environment ---"
Set-MaxEnvironment

# Install Deadline Cloud for 3ds Max
Write-Host "--- Installing deadline-cloud-for-3ds-max ---"
& "$MAX_INSTALL_DIR\Python\python.exe" -m ensurepip 2>&1 | ForEach-Object { Write-Host $_ }
& "$MAX_INSTALL_DIR\Python\python.exe" -m pip install deadline-cloud-for-3ds-max 2>&1 | ForEach-Object { Write-Host $_ }

# Mark install complete (persistent volume: skip on next boot)
if ($PERSISTENCE_ENABLED) {
    New-Item -ItemType File -Path $INSTALL_MARKER -Force | Out-Null
    Write-Host "Install marker written: $INSTALL_MARKER"
}

Write-Host "=== Installation complete ==="
Exit 0
