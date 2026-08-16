#Requires -Version 5.1

<#
.SYNOPSIS
    Holds a Windows sleep suppression for as long as this process lives.

.DESCRIPTION
    The execution state set here belongs to this process, so ending the process
    ends the suppression. That is how wakeguard.sh releases it: it calls
    Stop-Process, and the finally block never runs. The finally is there for a
    Ctrl+C, which does unwind.

.LINK
    https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setthreadexecutionstate

.EXAMPLE
    .\wakeguard-hold.ps1

.EXAMPLE
    .\wakeguard-hold.ps1 -TimeoutHours 2 -KeepDisplayOn
#>

[CmdletBinding()]
param(
    [ValidateRange(0.001, 168)]
    [double]$TimeoutHours = 8,

    [switch]$KeepDisplayOn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Name Power -Namespace WakeGuard -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@

# Decimal, not hex: PowerShell 5.1 reads 0x80000000 as Int32 -2147483648, which
# then refuses to cast to [uint32].
$ES_CONTINUOUS = [uint32]2147483648      # 0x80000000
$ES_SYSTEM_REQUIRED = [uint32]1
$ES_DISPLAY_REQUIRED = [uint32]2

$flags = $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED
if ($KeepDisplayOn) {
    $flags = $flags -bor $ES_DISPLAY_REQUIRED
}

if ([WakeGuard.Power]::SetThreadExecutionState($flags) -eq 0) {
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "SetThreadExecutionState(0x$($flags.ToString('X8'))) failed with GetLastError=$err"
}

try {
    # Not while ($true): a holder nobody ever kills has to give up on its own,
    # or the machine never sleeps again.
    $deadline = (Get-Date).AddHours($TimeoutHours)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
    }
}
finally {
    [void][WakeGuard.Power]::SetThreadExecutionState($ES_CONTINUOUS)
}
