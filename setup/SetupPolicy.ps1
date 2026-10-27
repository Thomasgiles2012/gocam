function Resolve-GoProBundleFile([string]$Root, [string]$Relative) {
    if ($Relative -notmatch '^[A-Za-z0-9 _.-]+(?:/[A-Za-z0-9 _.-]+)*$' -or
        @($Relative.Split('/') | Where-Object {$_ -in @('.','..') -or $_.EndsWith('.') -or $_.EndsWith(' ')}).Count) {
        throw 'The bundle identity file contains an unsafe relative path.'
    }
    return [IO.Path]::GetFullPath([IO.Path]::Combine($Root,$Relative))
}
function Get-GoProCandidate([object[]]$Adapters) {
    $matches = @($Adapters | Where-Object {
        $_.Up -and $_.Description -match '(?i)GoPro|UsbNcm|RNDIS' -and
        $_.Address -match '^172\.(?:\d{1,3})\.(?:\d{1,3})\.52$' -and
        [System.Net.IPAddress]::TryParse($_.Address, [ref]([System.Net.IPAddress]$null))
    })
    if ($matches.Count -eq 0) { throw 'No GoPro USB connection found. Plug in and power on the GoPro, then run First-Time Setup again.' }
    if ($matches.Count -ne 1) { throw 'More than one GoPro USB connection was found. Leave only the camera you want connected, then run setup again.' }
    return $matches[0]
}
function New-GoProFirewallPlan([string]$Receiver, $Camera) {
    if ($Receiver -notmatch '^[A-Za-z]:\\' -or [IO.Path]::GetFileName($Receiver) -cne 'GoProDeviceReceiver.exe') {
        throw 'Run setup from a local extracted folder containing GoProDeviceReceiver.exe, not a ZIP or network share.'
    }
    $program = [IO.Path]::GetFullPath($Receiver)
    $selected = Get-GoProCandidate @($Camera)
    if ([string]::IsNullOrWhiteSpace($selected.Name) -or $selected.Name -match '[\x00-\x1f*]') { throw 'The USB interface name is invalid.' }
    $address = [System.Net.IPAddress]::Parse($selected.Address)
    $bytes = $address.GetAddressBytes(); $bytes[3] = 51
    $digest = [Security.Cryptography.SHA256]::Create()
    try { $id = -join ($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($program.ToLowerInvariant()))[0..11] | ForEach-Object { $_.ToString('x2') }) }
    finally { $digest.Dispose() }
    [pscustomobject]@{
        Name = "GoPro Low Latency USB v1 $id"
        Description = "GoProLowLatency-Portable-USB-v1:$id"
        Program = $program; Protocol = 17; LocalPorts = '8554'
        LocalAddresses = $address.ToString(); RemoteAddresses = ([System.Net.IPAddress]::new($bytes)).ToString()
        Interface = $selected.Name; EdgeTraversal = $false
    }
}
function Test-GoProRuleOwner([string]$Name, [string]$Description, [string]$Program, $Plan) {
    return $Name -ceq $Plan.Name -and $Description -ceq $Plan.Description -and $Program -ieq $Plan.Program
}
function Get-GoProElevationCommand([string]$ScriptPath, [ValidateSet('Setup','Remove')][string]$Action) {
    $command = "& '" + $ScriptPath.Replace("'", "''") + "' -Action '$Action' -Elevated -Confirmed"
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
}
function Get-GoProSetupIntroduction([ValidateSet('Setup','Remove')][string]$Action) {
    if ($Action -eq 'Remove') { return 'Removes only this folder''s GoPro firewall rule, matching Windows camera registration and your matching sign-in entry. The GoPro does not need to be connected. App files and settings stay in place. Exit our tray app first if running this window as administrator.' }
    return 'Plug in and power on the GoPro. Wait for its USB mode/logo screen. Close camera use in Discord/Zoom and exit the official GoPro utility. Normal double-click setup closes our app before administrator approval; if this window is already administrator, Exit our tray app first.'
}
function Test-GoProSetupConfirmation([string]$Answer) { return $Answer.Trim() -ieq 'Y' }
function Test-GoProAdministrator {
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Test-GoProBundleProcessPath([string]$Path, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return $Path -ieq ([IO.Path]::Combine($Root,'Gocam.exe')) -or $Path -ieq ([IO.Path]::Combine($Root,'app\GoProDeviceReceiver.exe'))
}
function Stop-GoProBundleProcesses([string]$Root, $Manifest) {
    $locks=@(); $processes=@(); $helper=$null
    try {
        $processes=@(Get-Process -Name 'Gocam','GoProDeviceReceiver' -ErrorAction SilentlyContinue)
        $owned=@($processes | Where-Object { try { Test-GoProBundleProcessPath $_.Path $Root } catch { $false } })
        if (!$owned.Count) { return }
        if (Test-GoProAdministrator) { throw 'Exit our tray app and let camera cleanup finish, then run setup again. Administrator setup never launches a portable shutdown helper.' }
        foreach ($process in $owned) {
            $null=$process.Handle
            if (!(Test-GoProBundleProcessPath $process.Path $Root)) { throw 'A process changed identity before shutdown. No process was stopped.' }
        }
        Write-Host 'Closing our running app from this folder and restoring camera settings (normally a few seconds)...'
        foreach ($relative in @('Gocam.exe','app/GoProDeviceReceiver.exe')) {
            $path=Resolve-GoProBundleFile $Root $relative
            Assert-GoProPlainPath $path
            $expected=$Manifest.files.PSObject.Properties[$relative]
            if (!$expected -or $expected.Value -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Process cleanup refused: executable identity is missing.' }
            $locks+=,[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            if ((Get-FileHash -LiteralPath $path).Hash -ine $expected.Value) { throw 'Process cleanup refused: an app executable changed. Extract a complete matching download.' }
        }
        if (@($owned | Where-Object {$_.Path -ieq (Join-Path $Root 'Gocam.exe')}).Count) {
            # The app's normal Exit restores camera settings before releasing its receiver.
            $helper=Start-Process -FilePath (Join-Path $Root 'Gocam.exe') -ArgumentList '--request-exit' -WindowStyle Hidden -PassThru
            if (!$helper.WaitForExit(47000) -or $helper.ExitCode -ne 0) { throw 'Our app is still restoring camera settings or waiting for cleanup. Finish its cleanup message, then run setup again. No processes were forcibly stopped.' }
        }
        # Re-query after graceful exit so a receiver started during shutdown cannot be left behind.
        $processes+=@(Get-Process -Name 'Gocam','GoProDeviceReceiver' -ErrorAction SilentlyContinue)
        foreach ($process in $processes) {
            $ours=$false
            try { $ours=Test-GoProBundleProcessPath $process.Path $Root } catch { }
            if ($ours -and !$process.HasExited) { throw 'Our video receiver is still running or restoring camera settings. Let normal app cleanup finish, then run setup again. It was not forcibly stopped because that could lose the original camera settings.' }
        }
    } finally {
        if ($helper) { $helper.Dispose() }
        foreach ($process in $processes) { $process.Dispose() }
        foreach ($file in $locks) { $file.Dispose() }
    }
}
function Assert-GoProBundleStopped([string]$Root) {
    $processes=@(Get-Process -Name 'Gocam','GoProDeviceReceiver' -ErrorAction SilentlyContinue)
    try {
        foreach ($process in $processes) {
            if (!$process.HasExited -and (Test-GoProBundleProcessPath $process.Path $Root)) { throw 'Exit our tray app and let camera cleanup finish, then run setup again. No portable executable was launched with administrator privileges.' }
        }
    } finally { foreach ($process in $processes) { $process.Dispose() } }
}
function Remove-GoProStartupValue($Key,[string]$Root) {
    if (!$Key) { return }
    $name='GoPro Low Latency'
    $expected='"'+[IO.Path]::Combine([IO.Path]::GetFullPath($Root),'Gocam.exe')+'" --autostart'
    $value=$Key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if ($value -is [string] -and $Key.GetValueKind($name) -eq [Microsoft.Win32.RegistryValueKind]::String -and
        [string]::Equals($value,$expected,[StringComparison]::OrdinalIgnoreCase)) { $Key.DeleteValue($name,$false) }
}
function Remove-GoProStartupEntry([string]$Root) {
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run',$true)
    try { Remove-GoProStartupValue $key $Root }
    finally { if ($key) { $key.Dispose() } }
    Write-Host 'This folder''s matching Windows sign-in entry is disabled; other startup entries were left unchanged.'
}
function Assert-GoProPlainPath([string]$Path) {
    $part = [IO.Path]::GetFullPath($Path)
    while ($part) {
        if ((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'A setup path is a junction or symbolic link. Use a normal local extracted folder.'
        }
        $parent = [IO.Path]::GetDirectoryName($part)
        if ($parent -eq $part) { break }
        $part = $parent
    }
}
function Assert-GoProRemovalOwner($Registration, [string]$Hash, [string]$SourcePath) {
    if (!$Registration) { return }
    if ($Registration.Owner -cne 'GoProOriginalCamera-389E9F71-v1' -or $Registration.Hash -ine $Hash -or
        $Registration.Path -ine $SourcePath -or $Registration.Threading -cne 'Both' -or $Registration.ExtraEntries -ne 0) {
        throw 'The camera registration does not exactly match this build, or contains additional entries. Nothing will be removed.'
    }
}
function Assert-GoProIdleStatus([string]$Body) {
    if ($Body.Length -gt 4096) { throw 'The camera status response is too large.' }
    $status = $Body | ConvertFrom-Json
    if (!$status -or $status -is [array] -or
        ($status.error -isnot [int] -and $status.error -isnot [long]) -or $status.error -ne 0 -or
        ($status.status -isnot [int] -and $status.status -isnot [long]) -or $status.status -notin @(0,1)) {
        throw 'Close GoPro preview and other camera use before setup. No camera commands were sent.'
    }
}
function Get-GoProCompletionText([ValidateSet('Setup','Remove')][string]$Action) {
    if ($Action -eq 'Remove') { return 'SUCCESS: This folder''s firewall rule and matching Windows camera registration are removed. Your portable folder, settings and protected component files were retained.' }
    return 'SUCCESS: Windows camera and USB-only firewall setup completed. Normal double-click setup opens the app automatically. If this window was already administrator, close it and Open Gocam.exe normally (not as administrator).'
}
function Remove-GoProConfiguration($Rules, $Plan, [object[]]$Prior, [scriptblock]$RemoveComponent, [scriptblock]$RestoreComponent) {
    if ($Prior.Count -gt 1) { throw 'Duplicate setup rules need review. Nothing was removed.' }
    foreach ($rule in $Prior) {
        if (!(Test-GoProRuleOwner $rule.Name $rule.Description $rule.ApplicationName $Plan)) { throw 'A different program owns the firewall rule. Nothing was removed.' }
    }
    $ruleTouched=$false; $componentTouched=$false
    try {
        if ($Prior.Count) { $Rules.Remove($Plan.Name); $ruleTouched=$true }
        $componentTouched=$true; & $RemoveComponent
    } catch {
        $failure=$_; $rollbackFailed=$false
        if ($componentTouched) { try { & $RestoreComponent } catch { $rollbackFailed=$true } }
        if ($ruleTouched) { try { foreach ($rule in $Prior) { $Rules.Add($rule) } } catch { $rollbackFailed=$true } }
        if ($rollbackFailed) { throw 'Removal failed and automatic repair could not complete. Leave the app files in place and review Windows setup before using the camera.' }
        throw $failure
    }
}
