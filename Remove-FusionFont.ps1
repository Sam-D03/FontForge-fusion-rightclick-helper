[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $FontName,

    [switch] $ShowMessage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:SystemFontRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$Script:UserFontRegistryPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

function Show-RemoveMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,

        [ValidateSet('Information', 'Error', 'Warning')]
        [string] $Icon = 'Information'
    )

    if (-not $ShowMessage) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'Fusion Font Repair',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::$Icon
    ) | Out-Null
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-Argument {
    param([Parameter(Mandatory = $true)][string] $Value)
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value -replace '\\', '\\' -replace '"', '\"') + '"'
}

function Start-ElevatedSelf {
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $PSCommandPath,
        $FontName
    )
    if ($ShowMessage) {
        $arguments += '-ShowMessage'
    }

    $argumentString = ($arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    $process = Start-Process -FilePath $powershell -ArgumentList $argumentString -Verb RunAs -PassThru -Wait
    exit $process.ExitCode
}

function Get-FontRegistryMatches {
    param([Parameter(Mandatory = $true)][string] $Lookup)

    $registrySources = @(
        @{
            Scope = 'System'
            Path = $Script:SystemFontRegistryPath
            Folder = Join-Path $env:WINDIR 'Fonts'
        },
        @{
            Scope = 'User'
            Path = $Script:UserFontRegistryPath
            Folder = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
        }
    )

    foreach ($source in $registrySources) {
        if (-not (Test-Path -LiteralPath $source.Path)) {
            continue
        }

        $registryItem = Get-ItemProperty -LiteralPath $source.Path
        foreach ($property in $registryItem.PSObject.Properties) {
            if ($property.MemberType -ne 'NoteProperty') {
                continue
            }

            $displayName = ($property.Name -replace '\s+\((TrueType|OpenType|Type 1)\)$', '').Trim()
            $fontValue = [string] $property.Value
            $fontPath = if ([System.IO.Path]::IsPathRooted($fontValue)) {
                $fontValue
            }
            else {
                Join-Path $source.Folder $fontValue
            }

            if (
                $displayName -ieq $Lookup -or
                $property.Name -ieq $Lookup -or
                $fontValue -ieq $Lookup -or
                (Split-Path -Leaf $fontValue) -ieq $Lookup -or
                $displayName -like "$Lookup *"
            ) {
                [pscustomobject]@{
                    Scope = $source.Scope
                    RegistryPath = $source.Path
                    RegistryName = $property.Name
                    DisplayName = $displayName
                    FontPath = $fontPath
                }
            }
        }
    }
}

function Invoke-FontRefresh {
    $source = @'
using System;
using System.Runtime.InteropServices;

public static class FusionFontRepairRemoveNative {
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool RemoveFontResourceW(string lpFileName);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SendNotifyMessage(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, string dwItem1, string dwItem2);
}
'@
    Add-Type -TypeDefinition $source -ErrorAction SilentlyContinue
}

try {
    $matches = @(Get-FontRegistryMatches -Lookup $FontName)
    if ($matches.Count -eq 0) {
        throw "No installed Fusion font matched '$FontName'."
    }

    if (($matches | Where-Object { $_.Scope -eq 'System' }) -and -not (Test-IsAdministrator)) {
        Write-Host 'Administrator permission is required to remove a system-wide font. Requesting elevation...'
        Start-ElevatedSelf
    }

    Invoke-FontRefresh
    $removed = New-Object System.Collections.Generic.List[string]

    foreach ($match in $matches) {
        if (Test-Path -LiteralPath $match.FontPath) {
            [FusionFontRepairRemoveNative]::RemoveFontResourceW($match.FontPath) | Out-Null
        }

        Remove-ItemProperty -LiteralPath $match.RegistryPath -Name $match.RegistryName -ErrorAction SilentlyContinue

        if (Test-Path -LiteralPath $match.FontPath) {
            Remove-Item -LiteralPath $match.FontPath -Force -ErrorAction Stop
        }

        [FusionFontRepairRemoveNative]::SHChangeNotify(0x00002000, 0x0005, $match.FontPath, $null)
        $removed.Add("$($match.DisplayName) -> $($match.FontPath)")
    }

    [FusionFontRepairRemoveNative]::SendNotifyMessage([IntPtr] 0xffff, 0x001d, [UIntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    [FusionFontRepairRemoveNative]::SHChangeNotify(0x08000000, 0x0000, $null, $null)

    $message = "Removed:`n$($removed -join [Environment]::NewLine)"
    Write-Host $message
    Show-RemoveMessage -Message $message -Icon Information
    exit 0
}
catch {
    $message = $_.Exception.Message
    Write-Error $message
    Show-RemoveMessage -Message $message -Icon Error
    exit 1
}
