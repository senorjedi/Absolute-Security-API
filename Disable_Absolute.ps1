#POC: Sean Allen
$LogFile = "$PSScriptRoot\DisableAbsolute.log"
Add-Content $LogFile ("-" * 120)
Add-Content $LogFile ("Script running from: $PSScriptRoot")
$CCTK = "$PSScriptRoot\CCTK_5.2.1.16\cctk.exe"
$AbtPS = "$PSScriptRoot\AbtPS_SDK_1.3\AbtPS.exe"

Function Now { Return (Get-Date -Format G) }

#This will start and check the call
Function StartCall {
    Add-Content -Path $LogFile -Value "$(Now) - Starting call to server"
    $Timeout = 150

    do {
        $StartCall = Start-Process -FilePath $AbtPS -ArgumentList "-StartCall" -WindowStyle Hidden -PassThru -Wait
        $SleepCount = 10
        Add-Content -Path $LogFile -Value "$(Now) - Call has not completed, waiting $SleepCount seconds..."
        $Timeout = $Timeout - $SleepCount
        Start-Sleep -Seconds $SleepCount
        $IsCalling = Start-Process -FilePath $AbtPS -ArgumentList "-IsCalling" -WindowStyle Hidden -PassThru -Wait
    } until ($IsCalling.ExitCode -eq 1 -or $Timeout -le 0)

    if ($IsCalling.ExitCode -eq 1) {
        Add-Content -Path $LogFile -Value "$(Now) - Absolute is calling"
        return $true
    }
    elseif ($Timeout -le 0) {
        Add-Content -Path $LogFile -Value "$(Now) - Absolute is not calling"
        return $false
    }
}

#This will check if the call was successful
Function LastCall {
    Start-Sleep -Seconds 10
    Add-Content -Path $LogFile -Value "$(Now) - Checking if the result was successful"
    $Timeout = 150

    do {
        $SleepCount = 10
        Add-Content -Path $LogFile -Value "$(Now) - Result has not completed, waiting $SleepCount seconds..."
        $Timeout = $Timeout - $SleepCount
        Start-Sleep -Seconds $SleepCount
        $LastCallResult = Start-Process -FilePath $AbtPS -ArgumentList "-LastCallResult" -WindowStyle Hidden -PassThru -Wait

        if ($LastCallResult.ExitCode -eq 0) {
            Add-Content -Path $LogFile -Value "$(Now) - Failed to call"
            return $false
            break
        }
    } until ($LastCallResult.ExitCode -eq 2 -or $Timeout -le 0)

    if ($LastCallResult.ExitCode -eq 2) {
        Add-Content -Path $LogFile -Value "$(Now) - The call was a success"
        return $true
    }
}

#This is to create a scheduled task to re-run this script after reboot
function AbsoluteRebootTask {
    param (
        [string]$taskName = "AbsoluteBiosTask"
    )
    try {
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    }
    catch {
        $existing = $null
    }

    if ($existing) {
        Add-Content -Path $LogFile -Value "$(Now) - Scheduled task '$taskName' already exists."
        return
    }

    Add-Content -Path $LogFile -Value "$(Now) - Creating scheduled task '$taskName' that runs this script at startup as SYSTEM."

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-ExecutionPolicy Bypass -File `"$PSScriptRoot\Disable_Absolute.ps1`""

    $trigger = New-ScheduledTaskTrigger -AtStartup

    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null

    Add-Content -Path $LogFile -Value "$(Now) - Scheduled task '$taskName' created."
}

#Validate Absolute is installed
Add-Content -Path $LogFile -Value "$(Now) - Validating if Absolute is installed"

if (!(Get-Service RPCNET -ErrorAction SilentlyContinue)) {
    $Timeout = 600

    do {
        $SleepCount = 10
        Add-Content -Path $LogFile -Value "$(Now) - Absolute is not installed, waiting $SleepCount seconds..."
        $Timeout = $Timeout - $SleepCount
        Start-Sleep -Seconds $SleepCount
    } until ((Get-Service RPCNET -ErrorAction SilentlyContinue) -or $Timeout -le 0)

    if ($Timeout -le 0) {
        Add-Content -Path $LogFile -Value "$(Now) - Absolute is not installed and 10 minute timeout reached"
        Exit 0
    }
}

Add-Content -Path $LogFile -Value "$(Now) - Absolute is installed"

#Check persistence status first to determine the path
Add-Content -Path $LogFile -Value "$(Now) - Checking persistence status"
$persistence = Start-Process -FilePath $AbtPS -Wait -ArgumentList "-Status" -PassThru -WindowStyle Hidden

if ($persistence.ExitCode -eq 1) {
    #Persistence is active, need to deactivate via server call
    Add-Content -Path $LogFile -Value "$(Now) - Persistence is active, starting server call to deactivate"

    $calling = StartCall
    $checker = LastCall

    #Retries if the call was a failure
    $i = 0
    while ($checker -eq $false) {
        $i++
        Add-Content -Path $LogFile -Value "$(Now) - Retrying to call, attempt $i"
        $calling = StartCall
        $checker = LastCall
        if ($i -eq 2) {
            Add-Content -Path $LogFile -Value "$(Now) - Was not able to successfully call the server/cloud"
            break
        } else {
            Continue
        }
    }

    #Check reboots required for deactivation
    Add-Content -Path $LogFile -Value "$(Now) - Checking reboots required for deactivate"
    $activation = Start-Process -FilePath $AbtPS -Wait -ArgumentList "-RebootsRequired:Deactivated" -PassThru -WindowStyle Hidden
    $amount = $activation.ExitCode

    if ($amount -gt 0) {
        Add-Content -Path $LogFile -Value "$(Now) - Laptop needs $amount reboots to deactivate"
    } else {
        Add-Content -Path $LogFile -Value "$(Now) - No reboots needed for deactivate"
    }

    #Check if a reboot is needed
    Add-Content -Path $LogFile -Value "$(Now) - Checking Reboots"
    $reboot = Start-Process -FilePath $AbtPS -Wait -ArgumentList "-ReadyForReboot" -PassThru -WindowStyle Hidden

    if ($reboot.ExitCode -eq 1) {
        Add-Content -Path $LogFile -Value "$(Now) - Laptop needs to be rebooted"
        AbsoluteRebootTask
        Restart-Computer -Force
    } else {
        Add-Content -Path $LogFile -Value "$(Now) - No pending reboots, re-checking persistence"
        # Re-check persistence after server call with no reboot needed
        $persistence = Start-Process -FilePath $AbtPS -Wait -ArgumentList "-Status" -PassThru -WindowStyle Hidden
        if ($persistence.ExitCode -eq 0) {
            Add-Content -Path $LogFile -Value "$(Now) - Persistence is now deactivated, proceeding to disable in BIOS"
            # Fall through to BIOS disable below
        } else {
            Add-Content -Path $LogFile -Value "$(Now) - Persistence still active after server call, exiting"
            Exit 0
        }
    }

} elseif ($persistence.ExitCode -eq 0) {
    Add-Content -Path $LogFile -Value "$(Now) - Persistence is not active, proceeding to disable in BIOS"
}

#Disable Absolute in the BIOS (reached when persistence is confirmed deactivated)
Add-Content -Path $LogFile -Value "$(Now) - Validating Absolute status in the BIOS"
$BiosAbsoluteStatus = & $CCTK --Absolute 2>&1

if ($BiosAbsoluteStatus -eq 'Absolute=EnableAbsolute') {
    Add-Content -Path $LogFile -Value "$(Now) - Absolute is enabled in the BIOS"
    Add-Content -Path $LogFile -Value "$(Now) - Disabling Absolute in the BIOS..."
    $DisableAbsoluteBios = & $CCTK --Absolute=Disabled 2>&1

    #Validate the change
    Add-Content -Path $LogFile -Value "$(Now) - Validating Absolute status in the BIOS"
    $BiosAbsoluteStatus = & $CCTK --Absolute 2>&1

    if ($BiosAbsoluteStatus -eq 'Absolute=DisableAbsolute') {
        Add-Content -Path $LogFile -Value "$(Now) - Successfully disabled Absolute in the BIOS"
    } else {
        Add-Content -Path $LogFile -Value "$(Now) - Failed to disable Absolute in the BIOS"
    }
} else {
    Add-Content -Path $LogFile -Value "$(Now) - Absolute is already disabled in the BIOS"
    Exit 0
}