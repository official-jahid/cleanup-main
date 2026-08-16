#requires -Version 5.1
<#
.SYNOPSIS
    Performs conservative Windows maintenance without deleting diagnostic or forensic records.

.DESCRIPTION
    Removes old contents from temporary directories and, optionally, common graphics-shader
    caches. It does NOT clear Event Logs, USN journals, Prefetch, BAM, MFT data, registry
    transaction logs, USB history, or other persistence/diagnostic artifacts.

    The script can collect read-only diagnostics for Event IDs 41 and 6008, selected USB/
    device-related event channels, NTFS/USN journal status, and NTUSER.DAT transaction-log
    metadata. It can also request an orderly, non-forced restart through ExitWindowsEx after
    the cleanup completes.

.NOTES
    Run in an elevated PowerShell window to clean the system Temp directory and collect all
    diagnostics. Test with -WhatIf before using removal options.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateRange(0, 30)]
    [int]$OlderThanDays = 2,

    [switch]$IncludeSystemTemp,

    [switch]$ClearShaderCache,

    [switch]$RunComponentCleanup,

    [switch]$RunNtfsScan,

    [switch]$CollectDiagnostics,

    [ValidateRange(5, 300)]
    [int]$RestartDelaySeconds = 15,

    [switch]$Restart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$script:StartedAt = Get-Date
$script:Root = Join-Path $env:ProgramData 'SafeWindowsMaintenance'
$script:LogPath = Join-Path $script:Root ("maintenance-{0}.log" -f $script:StartedAt.ToString('yyyyMMdd-HHmmss'))
$script:Errors = [System.Collections.Generic.List[string]]::new()
$script:Summary = [ordered]@{
    TempItemsRemoved = 0
    TempBytesRemoved = [int64]0
    ShaderItemsRemoved = 0
    ShaderBytesRemoved = [int64]0
    DiagnosticsCollected = $false
}

function Write-Status {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info','Warning','Error','Success')] [string]$Level = 'Info'
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    Write-Information -MessageData $line -InformationAction Continue
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Add-ScriptError {
    param([Parameter(Mandatory)] [string]$Message)
    [void]$script:Errors.Add($Message)
    Write-Status -Message $Message -Level Error
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DirectorySize {
    param([Parameter(Mandatory)] [string]$Path)
    [int64]$total = 0
    Get-ChildItem -LiteralPath $Path -Force -File -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { $total += [int64]$_.Length }
    return $total
}

function Remove-OldTempItem {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [int]$AgeDays,
        [Parameter(Mandatory)] [string]$Category
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-Status -Message "Skipping missing directory: $Path" -Level Warning
        return
    }

    $cutoff = (Get-Date).AddDays(-$AgeDays)
    Write-Status -Message "Scanning ${Category}: $Path (items older than $AgeDays day(s))."

    try {
        $items = @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff })
    } catch {
        Add-ScriptError "Could not enumerate ${Path}: $($_.Exception.Message)"
        return
    }

    foreach ($item in $items) {
        $length = if ($item.PSIsContainer) { Get-DirectorySize -Path $item.FullName } else { [int64]$item.Length }
        if ($PSCmdlet.ShouldProcess($item.FullName, "Remove old $Category item")) {
            try {
                Remove-Item -LiteralPath $item.FullName -Force -Recurse -ErrorAction Stop
                $script:Summary.TempItemsRemoved++
                $script:Summary.TempBytesRemoved += $length
            } catch {
                # Files in use, ACL-protected files, and reparse-point edge cases are skipped.
                Add-ScriptError "Skipped $($item.FullName): $($_.Exception.Message)"
            }
        }
    }
}

function Remove-ShaderCache {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param()

    $paths = @(
        (Join-Path $env:LOCALAPPDATA 'D3DSCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\DxCache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\GLCache'),
        (Join-Path $env:LOCALAPPDATA 'Intel\ShaderCache')
    ) | Select-Object -Unique

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        $bytesBefore = Get-DirectorySize -Path $path
        $items = @(Get-ChildItem -LiteralPath $path -Force -Recurse -ErrorAction SilentlyContinue)
        foreach ($item in $items) {
            if ($PSCmdlet.ShouldProcess($item.FullName, 'Remove graphics shader-cache item')) {
                try {
                    Remove-Item -LiteralPath $item.FullName -Force -Recurse -ErrorAction Stop
                    $script:Summary.ShaderItemsRemoved++
                } catch {
                    Add-ScriptError "Skipped shader-cache item $($item.FullName): $($_.Exception.Message)"
                }
            }
        }
        $bytesAfter = Get-DirectorySize -Path $path
        $script:Summary.ShaderBytesRemoved += [Math]::Max([int64]0, ($bytesBefore - $bytesAfter))
    }
}

function Write-Section {
    param([Parameter(Mandatory)] [string]$Title)
    Add-Content -LiteralPath $script:LogPath -Value "`r`n===== $Title =====" -Encoding UTF8
}

function Get-EventDiagnosticInfo {
    param([int]$Days = 30)

    $start = (Get-Date).AddDays(-$Days)
    Write-Section -Title "Shutdown and device diagnostics"
    Add-Content -LiteralPath $script:LogPath -Value ("Window: {0:u} to {1:u}" -f $start, (Get-Date)) -Encoding UTF8

    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 6008; StartTime = $start } -ErrorAction Stop |
            Select-Object -First 200 TimeCreated, Id, ProviderName, LevelDisplayName, Message)
        if ($events.Count -eq 0) {
            Add-Content -LiteralPath $script:LogPath -Value 'No Event ID 41 or 6008 records found in the selected window.' -Encoding UTF8
        } else {
            $events | Format-List | Out-String -Width 240 | Add-Content -LiteralPath $script:LogPath -Encoding UTF8
        }
    } catch {
        Add-ScriptError "Could not read System Event Log: $($_.Exception.Message)"
    }

    $channels = @(
        'Microsoft-Windows-DriverFrameworks-UserMode/Operational',
        'Microsoft-Windows-Kernel-PnP/Configuration',
        'Microsoft-Windows-UserPnp/DeviceInstall'
    )
    foreach ($channel in $channels) {
        Write-Section -Title "Read-only device channel: $channel"
        try {
            $deviceEvents = @(Get-WinEvent -FilterHashtable @{ LogName = $channel; StartTime = $start } -ErrorAction Stop |
                Select-Object -First 100 TimeCreated, Id, ProviderName, LevelDisplayName, Message)
            if ($deviceEvents.Count -eq 0) {
                Add-Content -LiteralPath $script:LogPath -Value 'No records returned.' -Encoding UTF8
            } else {
                $deviceEvents | Format-List | Out-String -Width 240 | Add-Content -LiteralPath $script:LogPath -Encoding UTF8
            }
        } catch {
            Add-Content -LiteralPath $script:LogPath -Value "Channel unavailable or unreadable: $($_.Exception.Message)" -Encoding UTF8
        }
    }

    $script:Summary.DiagnosticsCollected = $true
}

function Get-NtfsDiagnosticInfo {
    param([switch]$ScanNtfs)

    Write-Section -Title 'Read-only NTFS and USN status'
    $drives = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType = 3" -ErrorAction SilentlyContinue |
        Where-Object { $_.FileSystem -eq 'NTFS' } |
        Select-Object -ExpandProperty DeviceID)

    if ($drives.Count -eq 0) {
        Add-Content -LiteralPath $script:LogPath -Value 'No local NTFS volumes detected.' -Encoding UTF8
        return
    }

    foreach ($drive in $drives) {
        Add-Content -LiteralPath $script:LogPath -Value "`r`n--- $drive ---" -Encoding UTF8
        try {
            (& fsutil usn queryjournal $drive 2>&1 | Out-String -Width 240) |
                Add-Content -LiteralPath $script:LogPath -Encoding UTF8
        } catch {
            Add-Content -LiteralPath $script:LogPath -Value "USN query failed: $($_.Exception.Message)" -Encoding UTF8
        }
        try {
            (& fsutil fsinfo ntfsinfo $drive 2>&1 | Out-String -Width 240) |
                Add-Content -LiteralPath $script:LogPath -Encoding UTF8
        } catch {
            Add-Content -LiteralPath $script:LogPath -Value "NTFS info query failed: $($_.Exception.Message)" -Encoding UTF8
        }
        if ($ScanNtfs) {
            Add-Content -LiteralPath $script:LogPath -Value 'Starting read-only online NTFS scan (chkdsk /scan).' -Encoding UTF8
            try {
                (& chkdsk $drive /scan 2>&1 | Out-String -Width 240) |
                    Add-Content -LiteralPath $script:LogPath -Encoding UTF8
            } catch {
                Add-Content -LiteralPath $script:LogPath -Value "NTFS scan failed: $($_.Exception.Message)" -Encoding UTF8
            }
        }
    }
}

function Get-RegistryTransactionLogInfo {
    Write-Section -Title 'Registry transaction-log metadata (preserved)'
    $candidatePaths = @(
        (Join-Path $env:USERPROFILE 'NTUSER.DAT.LOG1'),
        (Join-Path $env:USERPROFILE 'NTUSER.DAT.LOG2'),
        (Join-Path $env:USERPROFILE 'UsrClass.dat.LOG1'),
        (Join-Path $env:USERPROFILE 'UsrClass.dat.LOG2')
    )

    foreach ($path in $candidatePaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            Add-Content -LiteralPath $script:LogPath -Value ("Preserved: {0}; Size={1} bytes; LastWriteTime={2:u}" -f $path, $item.Length, $item.LastWriteTime) -Encoding UTF8
        } else {
            Add-Content -LiteralPath $script:LogPath -Value "Not present or inaccessible: $path" -Encoding UTF8
        }
    }
}

function Add-RestartApi {
    if (-not ('SafeWindowsRestart.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace SafeWindowsRestart {
    public static class NativeMethods {
        private const uint TOKEN_QUERY = 0x0008;
        private const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
        private const uint SE_PRIVILEGE_ENABLED = 0x00000002;
        private const uint ERROR_NOT_ALL_ASSIGNED = 1300;
        private const uint EWX_REBOOT = 0x00000002;
        private const uint SHTDN_REASON_FLAG_PLANNED = 0x80000000;

        [StructLayout(LayoutKind.Sequential)]
        private struct LUID { public uint LowPart; public int HighPart; }

        [StructLayout(LayoutKind.Sequential)]
        private struct TOKEN_PRIVILEGES {
            public uint PrivilegeCount;
            public LUID Luid;
            public uint Attributes;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges,
            ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool ExitWindowsEx(uint uFlags, uint dwReason);

        public static void RestartCleanly() {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed");

            try {
                LUID luid;
                if (!LookupPrivilegeValue(null, "SeShutdownPrivilege", out luid))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "LookupPrivilegeValue failed");

                TOKEN_PRIVILEGES privileges = new TOKEN_PRIVILEGES {
                    PrivilegeCount = 1,
                    Luid = luid,
                    Attributes = SE_PRIVILEGE_ENABLED
                };

                if (!AdjustTokenPrivileges(token, false, ref privileges, 0, IntPtr.Zero, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "AdjustTokenPrivileges failed");
                if (Marshal.GetLastWin32Error() == ERROR_NOT_ALL_ASSIGNED)
                    throw new Win32Exception(ERROR_NOT_ALL_ASSIGNED, "SeShutdownPrivilege was not assigned");
            } finally {
                CloseHandle(token);
            }

            // Deliberately omits EWX_FORCE. Windows broadcasts the normal session-end messages
            // and can display the standard shutdown UI when an application blocks shutdown.
            if (!ExitWindowsEx(EWX_REBOOT, SHTDN_REASON_FLAG_PLANNED))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "ExitWindowsEx failed");
        }
    }
}
'@
    }
}

# Prepare the report directory before any cleanup begins.
try {
    New-Item -ItemType Directory -Path $script:Root -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType File -Path $script:LogPath -Force -ErrorAction Stop | Out-Null
} catch {
    throw "Cannot create maintenance log at $script:LogPath. Run PowerShell with appropriate permissions. $($_.Exception.Message)"
}

Write-Status -Message 'Safe Windows maintenance started.'
Write-Status -Message "Log file: $script:LogPath"
if (-not (Test-IsAdministrator)) {
    Write-Status -Message 'PowerShell is not elevated. System-level cleanup and some diagnostics may be skipped.' -Level Warning
}

# User Temp is the default cleanup target; system Temp is opt-in.
$userTemp = [System.IO.Path]::GetTempPath()
Remove-OldTempItem -Path $userTemp -AgeDays $OlderThanDays -Category 'user temporary-file'
if ($IncludeSystemTemp) {
    Remove-OldTempItem -Path (Join-Path $env:windir 'Temp') -AgeDays $OlderThanDays -Category 'system temporary-file'
}

if ($ClearShaderCache) {
    Write-Status -Message 'Clearing selected graphics shader caches. They will be rebuilt by Windows or the driver.'
    Remove-ShaderCache
}

if ($RunComponentCleanup) {
    Write-Status -Message 'Running the official component-store cleanup. This may take several minutes.'
    if ($PSCmdlet.ShouldProcess('Windows component store', 'Run DISM StartComponentCleanup')) {
        try {
            $dismOutput = & dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart 2>&1
            $dismOutput | Add-Content -LiteralPath $script:LogPath -Encoding UTF8
        } catch {
            Add-ScriptError "DISM component cleanup failed: $($_.Exception.Message)"
        }
    }
}

if ($CollectDiagnostics) {
    Get-EventDiagnosticInfo
    Get-NtfsDiagnosticInfo -ScanNtfs:$RunNtfsScan
    Get-RegistryTransactionLogInfo
    Write-Status -Message 'Diagnostics were collected read-only and written to the maintenance log.'
}

# Flush only the DNS client cache; this does not remove event history.
try {
    if (Get-Command Clear-DnsClientCache -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess('DNS Client cache', 'Flush')) {
            Clear-DnsClientCache -ErrorAction Stop
            Write-Status -Message 'DNS client cache flushed.' -Level Success
        }
    }
} catch {
    Add-ScriptError "DNS cache flush skipped: $($_.Exception.Message)"
}

$elapsed = (Get-Date) - $script:StartedAt
Write-Status -Message ("Cleanup summary: {0} temp items, approximately {1:N0} bytes; {2} shader items, approximately {3:N0} bytes; elapsed {4}." -f $script:Summary.TempItemsRemoved, $script:Summary.TempBytesRemoved, $script:Summary.ShaderItemsRemoved, $script:Summary.ShaderBytesRemoved, $elapsed)
Write-Status -Message 'Event Logs, USN journals, Prefetch, BAM, MFT, registry transaction logs, USB history, and timestamps were not altered.' -Level Success

if ($Restart) {
    if (-not $PSCmdlet.ShouldProcess('Windows', "Restart cleanly in $RestartDelaySeconds seconds without EWX_FORCE")) {
        Write-Status -Message 'Restart declined by ShouldProcess/WhatIf.' -Level Warning
    } else {
        Write-Status -Message "A clean, non-forced restart will be requested in $RestartDelaySeconds seconds. Save your work now." -Level Warning
        Start-Sleep -Seconds $RestartDelaySeconds
        try {
            Add-RestartApi
            [SafeWindowsRestart.NativeMethods]::RestartCleanly()
        } catch {
            Add-ScriptError "Clean restart request failed: $($_.Exception.Message)"
        }
    }
}

if ($script:Errors.Count -gt 0) {
    Write-Status -Message ("Completed with {0} non-fatal issue(s). Review the log." -f $script:Errors.Count) -Level Warning
    exit 2
}

Write-Status -Message 'Safe Windows maintenance completed successfully.' -Level Success
exit 0
