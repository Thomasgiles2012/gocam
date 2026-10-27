param([ValidateSet('Setup','Remove')][string]$Action='Setup', [switch]$InspectOnly, [switch]$Elevated, [switch]$Confirmed)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$setupLock=$null; $setupLockHeld=$false
function Read-GoProRegistration([string]$Key) {
    $root=Get-Item -LiteralPath $Key -ErrorAction SilentlyContinue
    if (!$root) { return $null }
    $child=$null
    try {
        $child=$root.OpenSubKey('InprocServer32')
        $extra=@($root.GetSubKeyNames() | Where-Object { $_ -ne 'InprocServer32' }).Count +
            @($root.GetValueNames() | Where-Object { $_ -notin @('','GoProLowLatencyOwner','GoProLowLatencySourceSha256') }).Count
        if ($child) { $extra+=@($child.GetValueNames() | Where-Object { $_ -notin @('','ThreadingModel') }).Count + $child.GetSubKeyNames().Length }
        [pscustomobject]@{Owner=$root.GetValue('GoProLowLatencyOwner');Hash=$root.GetValue('GoProLowLatencySourceSha256');
            Path=$(if($child){$child.GetValue('')});Threading=$(if($child){$child.GetValue('ThreadingModel')});ExtraEntries=$extra;Default=$root.GetValue('')}
    } finally { if($child){$child.Dispose()}; $root.Dispose() }
}
function Restore-GoProRegistration([string]$Key, $Snapshot) {
    if (!$Snapshot) { return }
    $current=Read-GoProRegistration $Key
    if ($current -and $current.Owner -cne $Snapshot.Owner) { throw 'Registration changed ownership during removal; refusing to overwrite it.' }
    New-Item -Path $Key -Force | Out-Null
    New-ItemProperty -LiteralPath $Key -Name GoProLowLatencyOwner -Value $Snapshot.Owner -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $Key -Name GoProLowLatencySourceSha256 -Value $Snapshot.Hash -PropertyType String -Force | Out-Null
    if ($null -ne $Snapshot.Default) { Set-Item -LiteralPath $Key -Value $Snapshot.Default }
    $inproc=$Key+'\InprocServer32'
    New-Item -Path $inproc -Force | Out-Null
    Set-Item -LiteralPath $inproc -Value $Snapshot.Path
    New-ItemProperty -LiteralPath $inproc -Name ThreadingModel -Value $Snapshot.Threading -PropertyType String -Force | Out-Null
}
try {
    . (Join-Path $PSScriptRoot 'SetupPolicy.ps1')
    if (![Environment]::Is64BitProcess -or [Environment]::OSVersion.Version.Build -lt 22000) { throw 'This camera requires 64-bit Windows 11 (build 22000 or newer).' }
    $bundleRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    Assert-GoProPlainPath $bundleRoot
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'bundle-files.json') -Raw | ConvertFrom-Json
    if ($manifest.version -ne 2) { throw 'The bundle identity file is not supported. Extract a complete matching download.' }
    if (!$InspectOnly) {
        Write-Host ('Gocam - Windows ' + $Action) -ForegroundColor Cyan
        if (!$Confirmed) {
            Write-Host (Get-GoProSetupIntroduction $Action)
            if (!(Test-GoProSetupConfirmation (Read-Host 'Press Y to continue, or any other key then Enter to cancel'))) { Write-Host 'Cancelled. No changes were made.'; exit 2 }
        }
        if (!(Test-GoProAdministrator)) {
            if ($Elevated) { throw 'Administrator approval was not granted. No Windows settings were changed.' }
            Stop-GoProBundleProcesses $bundleRoot $manifest
            Write-Host 'Requesting administrator approval now. Approve the Windows prompt to continue.'
            $encoded = Get-GoProElevationCommand $PSCommandPath $Action
            $powershell = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
            try { $child = Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -Verb RunAs -WindowStyle Normal -Wait -PassThru }
            catch { throw 'Administrator approval was cancelled or blocked by your computer''s policy. No Windows settings were changed.' }
            if ($child.ExitCode -ne 0) { throw 'Windows setup did not complete. See the specific message in the administrator window; no app was launched.' }
            # Keep HKCU cleanup in the original user, even when UAC used another administrator account.
            if ($Action -eq 'Remove') { Remove-GoProStartupEntry $bundleRoot }
            Write-Host (Get-GoProCompletionText $Action) -ForegroundColor Green
            return
        }
        $setupLock=[Threading.Mutex]::new($false,'Local\GoProOriginalCameraSetup-389E9F71-7914-4ED1-A60C-25D50FDF0A84')
        try { $setupLockHeld=$setupLock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $setupLockHeld=$true }
        if (!$setupLockHeld) { throw 'Another camera setup is running. Let it finish before trying again.' }
        Write-Host '[1/4] Verifying package files...'
    }
    foreach ($entry in $manifest.files.PSObject.Properties) {
        if ($entry.Value -notmatch '^[A-Fa-f0-9]{64}$') { throw 'The bundle identity file contains an invalid hash.' }
        $file = Resolve-GoProBundleFile $bundleRoot $entry.Name
        Assert-GoProPlainPath $file
        if (!(Test-Path -LiteralPath $file -PathType Leaf) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.Value) { throw ('A bundle file is missing or changed: ' + $entry.Name + '. Extract a complete matching download; setup did not run.') }
    }
    foreach ($required in @('app/GoProDevice1080Source.dll','Gocam.exe','app/GoProDeviceReceiver.exe','setup/Install-Camera.ps1','setup/Remove-CameraComponent.ps1','setup/SetupPolicy.ps1','setup/Setup-Camera.ps1','app/GoProFramePipe.dll','app/GoProFullDecoder.dll')) {
        if (!$manifest.files.PSObject.Properties[$required]) { throw 'The bundle identity file is incomplete.' }
    }
    $sourceHash = $manifest.files.'app/GoProDevice1080Source.dll'
    $receiver = Join-Path $bundleRoot 'app/GoProDeviceReceiver.exe'
    $componentKey = 'HKLM:\SOFTWARE\Classes\CLSID\{389E9F71-7914-4ED1-A60C-25D50FDF0A84}'
    $registered = Read-GoProRegistration $componentKey
    if ($registered -and $registered.Owner -cne 'GoProOriginalCamera-389E9F71-v1') { throw 'A different program owns this Windows camera registration. Nothing will be overwritten.' }
    if (!$InspectOnly) {
        Write-Host '[2/4] Checking for our running app...'
        Assert-GoProBundleStopped $bundleRoot
        $active = $null
        try { $active = [Threading.Mutex]::OpenExisting('Local\GoProOriginalCameraTray-389E9F71-7914-4ED1-A60C-25D50FDF0A84') }
        catch [Threading.WaitHandleCannotBeOpenedException] { }
        if ($active) { $active.Dispose(); throw 'Our tray app is still running from another folder or Windows session. Exit that copy, then run setup again. Other applications were not stopped.' }
    }
    if ($Action -eq 'Setup') {
        # Removal must work without a camera or network adapter enumeration.
        if (!$InspectOnly) { Write-Host '[3/4] Finding the powered-on GoPro USB connection...' }
        $addresses=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)
        $adapters = @(Get-NetAdapter -IncludeHidden | ForEach-Object {
            $adapter = $_
            $addresses | Where-Object {$_.InterfaceIndex -eq $adapter.ifIndex} | ForEach-Object {
                [pscustomobject]@{ Name=$adapter.Name; Description=$adapter.InterfaceDescription; Up=($adapter.Status -eq 'Up'); Address=$_.IPAddress }
            }
        })
        $camera = Get-GoProCandidate $adapters
        $plan = New-GoProFirewallPlan $receiver $camera
        Add-Type -AssemblyName System.Net.Http
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.UseProxy=$false; $handler.AllowAutoRedirect=$false; $handler.UseDefaultCredentials=$false
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout=[TimeSpan]::FromSeconds(5); $client.MaxResponseContentBufferSize=4096
        try { Assert-GoProIdleStatus ($client.GetStringAsync('http://' + $plan.RemoteAddresses + '/gp/gpWebcam/STATUS').GetAwaiter().GetResult()) }
        catch { throw ('The GoPro did not confirm it is idle in USB mode. Close the official GoPro utility and camera use in Discord/Zoom; if needed reconnect/power on the GoPro, then run setup again. Detail: ' + $_.Exception.Message) }
        finally { $client.Dispose(); $handler.Dispose() }
    } else {
        # Rule identity depends only on this folder, not on whether a camera is connected.
        if (!$InspectOnly) { Write-Host '[3/4] Checking this folder''s setup ownership (no camera connection required)...' }
        $placeholder = [pscustomobject]@{Name='USB';Description='GoPro';Up=$true;Address='172.16.0.52'}
        $plan = New-GoProFirewallPlan $receiver $placeholder
        $expectedSource = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) ('GoPro Low Latency Camera\' + $sourceHash.Substring(0,24) + '\GoProDevice1080Source.dll')
        Assert-GoProRemovalOwner $registered $sourceHash $expectedSource
        if ($registered) {
            Assert-GoProPlainPath $expectedSource
        }
    }
    $firewall = New-Object -ComObject HNetCfg.FwPolicy2
    $prior = @($firewall.Rules | Where-Object { $_.Name -ceq $plan.Name })
    if ($prior.Count -gt 1) { throw 'Duplicate setup rules need review. No rules were changed.' }
    foreach ($rule in $prior) {
        if (!(Test-GoProRuleOwner $rule.Name $rule.Description $rule.ApplicationName $plan)) { throw 'Another rule uses this name. No rules were changed.' }
    }
    if ($InspectOnly) {
        Write-Output ([pscustomobject]@{action=$Action; dryRun=$true; sourceHash=$sourceHash; firewall=$plan; settings='settings/GoProCameraPreferences.ini'; systemChanges=$false} | ConvertTo-Json -Depth 4)
        return
    }
    $registered=Read-GoProRegistration $componentKey
    if ($registered -and $registered.Owner -cne 'GoProOriginalCamera-389E9F71-v1') { throw 'Registration changed ownership. Nothing will be overwritten.' }
    Write-Host '[4/4] Applying the Windows camera and scoped firewall configuration...'
    if ($Action -eq 'Remove') {
        Assert-GoProRemovalOwner $registered $sourceHash $expectedSource
        Remove-GoProConfiguration $firewall.Rules $plan $prior `
            { if ($registered) { & (Join-Path $PSScriptRoot 'Remove-CameraComponent.ps1') -Remove } } `
            { Restore-GoProRegistration $componentKey $registered }
        if (!$Elevated) { Remove-GoProStartupEntry $bundleRoot }
        Write-Host (Get-GoProCompletionText $Action) -ForegroundColor Green
        return
    }
    # Keep the DLL open read-only until its protected copy is verified and registered.
    $source = Join-Path $bundleRoot 'app/GoProDevice1080Source.dll'
    $sourceLock = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $ruleChanged = $false
    try {
        $desired = New-Object -ComObject HNetCfg.FWRule
        $desired.Name=$plan.Name; $desired.Description=$plan.Description; $desired.Grouping='Gocam Portable'
        $desired.ApplicationName=$plan.Program; $desired.Protocol=17; $desired.LocalPorts='8554'
        $desired.LocalAddresses=$plan.LocalAddresses; $desired.RemoteAddresses=$plan.RemoteAddresses
        $desired.Interfaces=@($plan.Interface); $desired.InterfaceTypes='All'; $desired.Profiles=7
        $desired.Direction=1; $desired.Action=1; $desired.EdgeTraversal=$false; $desired.Enabled=$true
        if ($prior.Count) { $firewall.Rules.Remove($plan.Name) }
        $ruleChanged=$true; $firewall.Rules.Add($desired)
        & (Join-Path $PSScriptRoot 'Install-Camera.ps1') -SourceDll $source -ExpectedSha256 $sourceHash
    } catch {
        if ($ruleChanged) {
            $firewall.Rules.Remove($plan.Name)
            foreach ($rule in $prior) { $firewall.Rules.Add($rule) }
        }
        throw
    } finally { $sourceLock.Dispose() }
    Write-Host (Get-GoProCompletionText $Action) -ForegroundColor Green
    Write-Host 'No firmware, certificates, permanent PowerShell policy, audio settings or other applications'' firewall rules were changed.'
} catch {
    Write-Host ('Setup could not complete: ' + $_.Exception.Message) -ForegroundColor Red
    if ($Elevated) { $null = (New-Object -ComObject WScript.Shell).Popup($_.Exception.Message, 0, 'Gocam Windows setup did not complete', 16) }
    exit 1
} finally {
    if ($setupLockHeld) { $setupLock.ReleaseMutex() }
    if ($setupLock) { $setupLock.Dispose() }
}
