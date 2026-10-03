# codex-windows-update-guard / Public Candidate V0.1
# Evidence first. Recovery second. This candidate has NOT been Apply-tested.
# Run with Windows PowerShell 5.1 -NoProfile -File from an independent console.
[CmdletBinding()]
param([switch]$Apply)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$script:PackageName = 'OpenAI.Codex'
$script:Family = 'OpenAI.Codex_2p2nqsd0c76g0'
$script:ServiceName = 'CodexSandboxService.OpenAI.Codex'
$script:ServiceLeaf = 'codex-windows-sandbox-service.exe'
$script:Changed = $false
$script:Phase = 'PLATFORM'
$script:CurrentVersion = 'NONE'
$script:TargetVersion = 'NONE'
$script:Architecture = 'UNKNOWN'
$script:CandidateCount = 0
$script:ServiceState = 'NOT_QUERIED'
$script:OriginalState = 'NOT_QUERIED'
$script:OriginalStartMode = 'NOT_QUERIED'
$script:OriginalProcessId = 0
$script:Mutex = $null
$script:OwnsMutex = $false
$script:ErrorCategory = 'NONE'
$script:Verdict = 'FAIL'
$script:State = 'NOT_STARTED'
$script:ExitCode = 20

function Stop-Guard {
    param([string]$Category, [switch]$Failure)
    $e = New-Object System.InvalidOperationException('Guard stopped; see error category.')
    $e.Data['GuardCategory'] = $Category
    $e.Data['GuardBlock'] = -not $Failure.IsPresent
    throw $e
}

function Get-CanonicalPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Stop-Guard 'PATH_UNRESOLVED'
    }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-InDirectory {
    param([string]$Path, [string]$Directory)
    $p = Get-CanonicalPath $Path
    $d = (Get-CanonicalPath $Directory) + '\'
    return $p.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparse {
    param([string]$Path)
    $cursor = Get-CanonicalPath $Path
    while ($cursor) {
        try { $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop }
        catch { Stop-Guard 'PATH_UNREADABLE' }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Guard 'REPARSE_PATH_UNSUPPORTED'
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-Platform {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or
        $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
        Stop-Guard 'WINDOWS_POWERSHELL_51_REQUIRED'
    }
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop
    $cpu = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 5 -ErrorAction Stop)
    $v = [version]$os.Version
    if ($os.ProductType -ne 1 -or $v.Major -ne 10 -or $v.Build -lt 10240 -or
        $v.Build -ge 22000 -or -not [Environment]::Is64BitProcess -or
        $cpu.Count -eq 0 -or @($cpu | Where-Object { $_.Architecture -ne 9 }).Count -gt 0) {
        Stop-Guard 'WINDOWS_10_X64_REQUIRED'
    }
    $script:Architecture = 'x64'
    foreach ($name in @('Get-AppxPackage','Add-AppxPackage','Get-CimInstance','Invoke-CimMethod','Stop-Service')) {
        try { $null = Get-Command $name -ErrorAction Stop }
        catch { Stop-Guard 'REQUIRED_COMMAND_UNAVAILABLE' }
    }
    if (-not (Get-Command Stop-Service).Parameters.ContainsKey('NoWait')) {
        Stop-Guard 'BOUNDED_SERVICE_STOP_UNAVAILABLE'
    }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        if ($Apply -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Stop-Guard 'APPLY_REQUIRES_ADMINISTRATOR'
        }
    } finally { $id.Dispose() }
}

function Enter-GuardMutex {
    # A denied or abandoned mutex is not evidence that maintenance is safe.
    try {
        $script:Mutex = New-Object Threading.Mutex($false, 'Global\CodexWindowsUpdateGuard.PublicCandidateV01')
        $script:OwnsMutex = $script:Mutex.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $script:OwnsMutex = $true
        Stop-Guard 'PREVIOUS_INSTANCE_ABANDONED'
    } catch { Stop-Guard 'MUTEX_UNAVAILABLE' }
    if (-not $script:OwnsMutex) { Stop-Guard 'ANOTHER_INSTANCE_RUNNING' }
}

function Initialize-WtsReader {
    if ('CodexUpdateGuardV01.WtsReader' -as [type]) { Stop-Guard 'REUSED_HOST_UNSUPPORTED' }
    # Read-only WTS APIs; no session logoff, disconnect or token manipulation.
    $native = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace CodexUpdateGuardV01 {
    public sealed class Session {
        public int Id; public int State; public string User; public string Domain;
    }
    public static class WtsReader {
        [StructLayout(LayoutKind.Sequential)]
        private struct Info { public int Id; public IntPtr Station; public int State; }
        [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern bool WTSEnumerateSessionsW(IntPtr server, int reserved, int version,
            out IntPtr buffer, out int count);
        [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern bool WTSQuerySessionInformationW(IntPtr server, int id, int kind,
            out IntPtr buffer, out int bytes);
        [DllImport("wtsapi32.dll", ExactSpelling=true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern void WTSFreeMemory(IntPtr memory);
        private static string Text(int id, int kind) {
            IntPtr b = IntPtr.Zero; int size;
            if (!WTSQuerySessionInformationW(IntPtr.Zero, id, kind, out b, out size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try { return size >= 2 ? (Marshal.PtrToStringUni(b) ?? "") : ""; }
            finally { if (b != IntPtr.Zero) WTSFreeMemory(b); }
        }
        public static Session[] Read() {
            IntPtr b = IntPtr.Zero; int count;
            if (!WTSEnumerateSessionsW(IntPtr.Zero, 0, 1, out b, out count))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                var result = new List<Session>(); int size = Marshal.SizeOf(typeof(Info));
                for (int i = 0; i < count; i++) {
                    Info s = (Info)Marshal.PtrToStructure(IntPtr.Add(b, i * size), typeof(Info));
                    // Session zero is noninteractive. State 6 is a listener, not a signed-in user.
                    if (s.Id == 0 || s.State == 6) continue;
                    result.Add(new Session { Id=s.Id, State=s.State, User=Text(s.Id,5), Domain=Text(s.Id,7) });
                }
                return result.ToArray();
            } finally { if (b != IntPtr.Zero) WTSFreeMemory(b); }
        }
    }
}
'@
    try { Add-Type -TypeDefinition $native -Language CSharp -ErrorAction Stop | Out-Null }
    catch { Stop-Guard 'SESSION_READER_UNAVAILABLE' }
}

function Assert-SingleDesktopUser {
    try { $sessions = @([CodexUpdateGuardV01.WtsReader]::Read()) }
    catch { Stop-Guard 'SESSION_VISIBILITY_INSUFFICIENT' }
    # Includes disconnected sessions: Fast User Switching is deliberately unsupported.
    if ($sessions.Count -ne 1 -or $sessions[0].State -ne 0 -or
        [string]::IsNullOrWhiteSpace($sessions[0].User) -or
        [string]::IsNullOrWhiteSpace($sessions[0].Domain)) { Stop-Guard 'SINGLE_ACTIVE_USER_REQUIRED' }
    $s = $sessions[0]
    try {
        $account = New-Object Security.Principal.NTAccount($s.Domain, $s.User)
        $desktopSid = $account.Translate([Security.Principal.SecurityIdentifier]).Value
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try { $tokenSid = $identity.User.Value } finally { $identity.Dispose() }
        $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    } catch { Stop-Guard 'USER_IDENTITY_UNRESOLVED' }
    if ($desktopSid -ne $tokenSid -or $s.Id -ne $sessionId) { Stop-Guard 'ELEVATED_USER_MISMATCH' }
    # SIDs are comparison data in memory only; never emitted to the log.
    return $tokenSid
}

function Assert-TrustedPackage {
    param($Package, [string]$ExpectedPublisher)
    foreach ($p in @('Name','PackageFamilyName','Publisher','Architecture','SignatureKind','IsDevelopmentMode',
                    'Status','Version','PackageFullName','InstallLocation','IsFramework','IsResourcePackage')) {
        if ($null -eq $Package -or -not $Package.PSObject.Properties[$p]) { Stop-Guard 'PACKAGE_METADATA_INCOMPLETE' }
    }
    if ($Package.Name -cne $script:PackageName -or $Package.PackageFamilyName -cne $script:Family -or
        [string]$Package.Architecture -ine 'X64' -or [string]$Package.SignatureKind -cne 'Store' -or
        $Package.IsDevelopmentMode -ne $false -or [string]$Package.Status -cne 'Ok' -or
        $Package.IsFramework -ne $false -or $Package.IsResourcePackage -ne $false -or
        [string]::IsNullOrWhiteSpace([string]$Package.Publisher)) { Stop-Guard 'UNTRUSTED_PACKAGE' }
    if ($ExpectedPublisher -and $Package.Publisher -cne $ExpectedPublisher) { Stop-Guard 'PUBLISHER_MISMATCH' }
    try { $version = [version]$Package.Version }
    catch { Stop-Guard 'INVALID_PACKAGE_VERSION' }
    foreach ($n in @($version.Major,$version.Minor,$version.Build,$version.Revision)) {
        if ($n -lt 0 -or $n -gt 65535) { Stop-Guard 'INVALID_PACKAGE_VERSION' }
    }
    $location = Get-CanonicalPath $Package.InstallLocation
    if ([IO.Path]::GetFileName($location) -cne $Package.PackageFullName -or
        [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($location)) -ine 'WindowsApps') {
        Stop-Guard 'PACKAGE_LOCATION_UNEXPECTED'
    }
    Assert-NoReparse $location
}

function Get-CurrentPackage {
    try { $packages = @(Get-AppxPackage -Name $script:PackageName -PackageTypeFilter Main -ErrorAction Stop) }
    catch { Stop-Guard 'CURRENT_PACKAGE_QUERY_FAILED' }
    if ($packages.Count -ne 1) { Stop-Guard 'CURRENT_PACKAGE_NOT_UNIQUE' }
    Assert-TrustedPackage $packages[0]
    return $packages[0]
}

function Get-StagedCandidate {
    param($Current)
    try { $all = @(Get-AppxPackage -AllUsers -Name $script:PackageName -PackageTypeFilter Main -ErrorAction Stop) }
    catch { Stop-Guard 'ALLUSERS_VISIBILITY_INSUFFICIENT' }
    if ($all.Count -eq 0 -or @($all | Where-Object { $_.PackageFullName -ceq $Current.PackageFullName }).Count -ne 1) {
        Stop-Guard 'ALLUSERS_SNAPSHOT_INCONSISTENT'
    }
    $candidates = @()
    foreach ($p in $all) {
        if (-not $p.PSObject.Properties['PackageUserInformation']) { Stop-Guard 'STAGE_METADATA_INCOMPLETE' }
        $states = @($p.PackageUserInformation)
        if ($states.Count -eq 0) { Stop-Guard 'STAGE_METADATA_INCOMPLETE' }
        $staged = $false
        foreach ($u in $states) {
            if ($null -eq $u -or -not $u.PSObject.Properties['InstallState']) { Stop-Guard 'STAGE_METADATA_INCOMPLETE' }
            $value = [string]$u.InstallState
            if ($value -notin @('NotInstalled','Staged','Installed')) { Stop-Guard 'STAGE_STATE_UNKNOWN' }
            if ($value -ceq 'Staged') { $staged = $true }
        }
        if (-not $staged) { continue }
        Assert-TrustedPackage $p $Current.Publisher
        if ([version]$p.Version -gt [version]$Current.Version) { $candidates += $p }
    }
    $script:CandidateCount = $candidates.Count
    if ($candidates.Count -gt 1) { Stop-Guard 'STAGED_CANDIDATE_AMBIGUOUS' }
    if ($candidates.Count -eq 0) { return $null }
    return $candidates[0]
}

function Get-VerifiedManifest {
    param($Package)
    $manifest = Join-Path $Package.InstallLocation 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { Stop-Guard 'MANIFEST_MISSING' }
    Assert-NoReparse $manifest
    $reader = $null; $stream = $null; $sha = $null
    try {
        $bytes = [IO.File]::ReadAllBytes($manifest)
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $stream = [IO.MemoryStream]::new($bytes, $false)
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        $doc = New-Object Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.Load($reader)
        $ns = New-Object Xml.XmlNamespaceManager($doc.NameTable)
        $ns.AddNamespace('a','http://schemas.microsoft.com/appx/manifest/foundation/windows10')
        $nodes = $doc.SelectNodes('/a:Package/a:Identity',$ns)
        if ($nodes.Count -ne 1) { Stop-Guard 'MANIFEST_IDENTITY_AMBIGUOUS' }
        $id = $nodes[0]
        if ($id.GetAttribute('Name') -cne $Package.Name -or
            $id.GetAttribute('Publisher') -cne $Package.Publisher -or
            $id.GetAttribute('Version') -cne ([version]$Package.Version).ToString() -or
            $id.GetAttribute('ProcessorArchitecture') -cne 'x64') { Stop-Guard 'MANIFEST_IDENTITY_MISMATCH' }
        $sha = [Security.Cryptography.SHA256]::Create()
        $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')
        return [pscustomobject]@{ Path=$manifest; Hash=$hash }
    } catch { Stop-Guard 'MANIFEST_INVALID_OR_UNREADABLE' }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $sha) { $sha.Dispose() }
    }
}

function Get-ExactService {
    $items = @(Get-CimInstance Win32_Service -Filter "Name='CodexSandboxService.OpenAI.Codex'" -OperationTimeoutSec 5 -ErrorAction Stop)
    if ($items.Count -ne 1) { Stop-Guard 'SERVICE_NOT_UNIQUE' }
    return $items[0]
}

function Assert-TargetServiceLayout {
    param($Target)
    try {
        $root = Get-CanonicalPath $Target.InstallLocation
        $binary = Join-Path $root ('app\resources\' + $script:ServiceLeaf)
        if (-not (Test-InDirectory $binary $root) -or
            -not (Test-Path -LiteralPath $binary -PathType Leaf)) {
            Stop-Guard 'TARGET_SERVICE_LAYOUT_UNRESOLVED'
        }
        Assert-NoReparse $binary
    } catch { Stop-Guard 'TARGET_SERVICE_LAYOUT_UNRESOLVED' }
}

function Assert-ServiceIdentity {
    param($Service, $Current)
    $expected = Join-Path $Current.InstallLocation ('app\resources\' + $script:ServiceLeaf)
    $raw = ([string]$Service.PathName).Trim()
    if ($raw.StartsWith('"')) {
        if ($raw -notmatch '^"([^\"]+)"\s*$') { Stop-Guard 'SERVICE_COMMAND_UNEXPECTED' }
        $raw = $Matches[1]
    }
    if ($Service.Name -cne $script:ServiceName -or
        (Get-CanonicalPath $raw) -ine (Get-CanonicalPath $expected) -or
        $Service.StartName -ine 'LocalSystem' -or $Service.StartMode -notin @('Auto','Manual')) {
        Stop-Guard 'SERVICE_IDENTITY_MISMATCH'
    }
    if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) { Stop-Guard 'SERVICE_BINARY_MISSING' }
    Assert-NoReparse $expected
}

function Get-OwnerSid {
    param($Process)
    try { $owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwnerSid -OperationTimeoutSec 5 -ErrorAction Stop }
    catch { Stop-Guard 'PROCESS_OWNER_UNRESOLVED' }
    if ($owner.ReturnValue -ne 0 -or [string]::IsNullOrWhiteSpace($owner.Sid)) { Stop-Guard 'PROCESS_OWNER_UNRESOLVED' }
    return [string]$owner.Sid
}

function Assert-PostRegisterService {
    param($Current)
    $script:ServiceState = 'UNKNOWN'
    try { $finalService = Get-ExactService }
    catch { Stop-Guard 'POST_REGISTER_SERVICE_UNRESOLVED' -Failure }
    try { Assert-ServiceIdentity $finalService $Current }
    catch { Stop-Guard 'POST_REGISTER_SERVICE_IDENTITY_MISMATCH' -Failure }
    if (-not $finalService.PSObject.Properties['State'] -or
        -not $finalService.PSObject.Properties['ProcessId'] -or
        $null -eq $finalService.State -or $null -eq $finalService.ProcessId) {
        Stop-Guard 'POST_REGISTER_SERVICE_UNRESOLVED' -Failure
    }
    $state = [string]$finalService.State
    if ($state -notin @('Running','Stopped')) {
        Stop-Guard 'POST_REGISTER_SERVICE_STATE_UNSTABLE' -Failure
    }
    if (($state -eq 'Stopped' -and $finalService.ProcessId -ne 0) -or
        ($state -eq 'Running' -and $finalService.ProcessId -le 0)) {
        Stop-Guard 'POST_REGISTER_SERVICE_PID_INCONSISTENT' -Failure
    }
    if ($state -eq 'Running') {
        try {
            $live = @(Get-CimInstance Win32_Process -Filter ('ProcessId=' + [uint32]$finalService.ProcessId) -OperationTimeoutSec 5 -ErrorAction Stop)
            if ($live.Count -ne 1 -or [string]::IsNullOrWhiteSpace($live[0].ExecutablePath)) {
                Stop-Guard 'POST_REGISTER_SERVICE_UNRESOLVED' -Failure
            }
            $expectedPath = Join-Path $Current.InstallLocation ('app\resources\' + $script:ServiceLeaf)
            $actualPath = Get-CanonicalPath $live[0].ExecutablePath
            $expectedPath = Get-CanonicalPath $expectedPath
            $ownerSid = Get-OwnerSid $live[0]
            $systemSid = (New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::LocalSystemSid,$null)).Value
        } catch { Stop-Guard 'POST_REGISTER_SERVICE_UNRESOLVED' -Failure }
        if ($actualPath -ine $expectedPath -or $ownerSid -ne $systemSid) {
            Stop-Guard 'POST_REGISTER_SERVICE_IDENTITY_MISMATCH' -Failure
        }
    }
    # Publish only the fully validated stable service snapshot.
    $script:ServiceState = $state
}

function Assert-ProcessGate {
    param($Current, $Target, $Service, [string]$UserSid, [switch]$AfterStop)
    $processes = @(Get-CimInstance Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop)
    $hostRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OpenAI\Codex\bin'
    $roots = @($Current.InstallLocation)
    if ($null -ne $Target) { $roots += $Target.InstallLocation }
    $systemSid = (New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::LocalSystemSid,$null)).Value
    foreach ($p in $processes) {
        $path = [string]$p.ExecutablePath
        $named = $p.Name -in @('ChatGPT.exe','Codex.exe','codex-windows-sandbox-service.exe')
        $isServicePid = $Service.ProcessId -gt 0 -and $p.ProcessId -eq $Service.ProcessId
        if (-not $path) {
            if ($named -or $isServicePid) { Stop-Guard 'RELATED_PROCESS_PATH_UNRESOLVED' }
            continue
        }
        $inPackage = $false
        foreach ($root in $roots) { if (Test-InDirectory $path $root) { $inPackage = $true } }
        $isHost = Test-InDirectory $path $hostRoot
        # A same-family package at another version is conservatively blocked too.
        $otherCodexPackage = $path -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+__2p2nqsd0c76g0\\'
        if (-not ($named -or $isServicePid -or $inPackage -or $isHost -or $otherCodexPackage)) { continue }
        $ownerSid = Get-OwnerSid $p
        if ($isServicePid -and -not $AfterStop) {
            $expected = Join-Path $Current.InstallLocation ('app\resources\' + $script:ServiceLeaf)
            if ((Get-CanonicalPath $path) -ine (Get-CanonicalPath $expected) -or $ownerSid -ne $systemSid) {
                Stop-Guard 'SERVICE_PROCESS_IDENTITY_MISMATCH'
            }
            continue
        }
        # A known name with a known unrelated path is not killed or treated as our UI.
        if ($inPackage -or $isHost -or $otherCodexPackage -or $p.Name -ieq $script:ServiceLeaf) {
            if ($ownerSid -ne $UserSid) { Stop-Guard 'RELATED_PROCESS_OTHER_USER' }
            Stop-Guard 'CODEX_UI_OR_HOST_RUNNING'
        }
    }
    # Refuse a maintenance process hosted by Codex, including AppData/standalone hosts.
    $nextPid = $PID; $seen = @{}; $finished = $false
    for ($i=0; $i -lt 64; $i++) {
        $hits = @($processes | Where-Object { $_.ProcessId -eq $nextPid })
        if ($hits.Count -ne 1 -or $seen.ContainsKey($nextPid)) { Stop-Guard 'ANCESTRY_UNRESOLVED' }
        $a = $hits[0]; $seen[$nextPid] = $true
        if ($a.Name -in @('ChatGPT.exe','Codex.exe','codex-windows-sandbox-service.exe')) { Stop-Guard 'CODEX_ANCESTOR' }
        if ([string]::IsNullOrWhiteSpace($a.ExecutablePath)) { Stop-Guard 'ANCESTRY_UNRESOLVED' }
        if ((Get-CanonicalPath $a.ExecutablePath) -ieq (Join-Path $env:SystemRoot 'explorer.exe')) {
            if ((Get-OwnerSid $a) -ne $UserSid) { Stop-Guard 'ANCESTRY_USER_MISMATCH' }
            $finished = $true; break
        }
        if ($a.ParentProcessId -eq 0) { $finished = $true; break }
        $parent = @($processes | Where-Object { $_.ProcessId -eq $a.ParentProcessId })
        if ($parent.Count -ne 1 -or $null -eq $parent[0].CreationDate -or $null -eq $a.CreationDate -or
            $parent[0].CreationDate -gt $a.CreationDate) { Stop-Guard 'ANCESTRY_UNRESOLVED' }
        $nextPid = $a.ParentProcessId
    }
    if (-not $finished) { Stop-Guard 'ANCESTRY_UNRESOLVED' }
}

function Get-Preflight {
    $script:Phase = 'USER'
    $userSid = Assert-SingleDesktopUser
    $script:Phase = 'CURRENT_PACKAGE'
    $current = Get-CurrentPackage
    $script:CurrentVersion = ([version]$current.Version).ToString()
    $null = Get-VerifiedManifest $current
    $script:Phase = 'STAGED_PACKAGE'
    $target = Get-StagedCandidate $current
    $manifest = $null
    if ($null -ne $target) {
        $script:TargetVersion = ([version]$target.Version).ToString()
        $script:Phase = 'MANIFEST'
        $manifest = Get-VerifiedManifest $target
        Assert-TargetServiceLayout $target
    }
    $script:Phase = 'SERVICE'
    $service = Get-ExactService
    Assert-ServiceIdentity $service $current
    $script:ServiceState = [string]$service.State
    if ($service.State -notin @('Running','Stopped') -or
        ($service.State -eq 'Stopped' -and $service.ProcessId -ne 0) -or
        ($service.State -eq 'Running' -and $service.ProcessId -eq 0)) { Stop-Guard 'SERVICE_NOT_STABLE' }
    $script:Phase = 'PROCESSES'
    Assert-ProcessGate $current $target $service $userSid
    $serviceCreation = $null
    if ($service.ProcessId -gt 0) {
        $live = @(Get-CimInstance Win32_Process -Filter ('ProcessId=' + [uint32]$service.ProcessId) -OperationTimeoutSec 5 -ErrorAction Stop)
        if ($live.Count -ne 1) { Stop-Guard 'SERVICE_PROCESS_UNRESOLVED' }
        $expectedPath = Join-Path $current.InstallLocation ('app\resources\' + $script:ServiceLeaf)
        $systemSid = (New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::LocalSystemSid,$null)).Value
        if ((Get-CanonicalPath $live[0].ExecutablePath) -ine (Get-CanonicalPath $expectedPath) -or
            (Get-OwnerSid $live[0]) -ne $systemSid -or $null -eq $live[0].CreationDate) { Stop-Guard 'SERVICE_PROCESS_UNRESOLVED' }
        $serviceCreation = $live[0].CreationDate
    }
    return [pscustomobject]@{ Current=$current; Target=$target; Manifest=$manifest; Service=$service; UserSid=$userSid; ServiceCreation=$serviceCreation }
}

function Assert-SamePreflight {
    param($Before, $Now)
    if ($null -eq $Now.Target -or $Before.UserSid -ne $Now.UserSid -or
        $Before.Current.PackageFullName -cne $Now.Current.PackageFullName -or
        $Before.Target.PackageFullName -cne $Now.Target.PackageFullName -or
        $Before.Manifest.Path -ine $Now.Manifest.Path -or $Before.Manifest.Hash -cne $Now.Manifest.Hash -or
        $Before.ServiceCreation -ne $Now.ServiceCreation) {
        Stop-Guard 'PREFLIGHT_CHANGED'
    }
    foreach ($k in @('State','ProcessId','PathName','StartName','StartMode')) {
        if ($Before.Service.$k -cne $Now.Service.$k) { Stop-Guard 'SERVICE_CHANGED_DURING_PREFLIGHT' }
    }
}

function Assert-Stopped {
    param($Current, [uint32]$OriginalPid)
    $s = Get-ExactService
    Assert-ServiceIdentity $s $Current
    $script:ServiceState = [string]$s.State
    $left = @()
    if ($OriginalPid -gt 0) { $left = @(Get-CimInstance Win32_Process -Filter ('ProcessId=' + $OriginalPid) -OperationTimeoutSec 5 -ErrorAction Stop) }
    if ($s.State -ne 'Stopped' -or $s.ProcessId -ne 0 -or $left.Count -ne 0) {
        Stop-Guard 'SERVICE_STOP_NOT_CONFIRMED' -Failure
    }
    return $s
}

function Invoke-ApplyRecovery {
    param($Evidence)
    # Defense in depth: this is the only function containing package/service writes.
    if (-not $Apply.IsPresent) { Stop-Guard 'APPLY_NOT_AUTHORIZED' }
    $fresh = Get-Preflight
    Assert-SamePreflight $Evidence $fresh
    $script:OriginalState = [string]$fresh.Service.State
    $script:OriginalStartMode = [string]$fresh.Service.StartMode
    $script:OriginalProcessId = [uint32]$fresh.Service.ProcessId
    $script:Phase = 'STOP_SERVICE'
    if ($fresh.Service.State -eq 'Running') {
        # Conservatively YES from dispatch: a throwing/partly completed write must never report NO.
        $script:Changed = $true
        Stop-Service -Name $script:ServiceName -NoWait -ErrorAction Stop -WarningAction SilentlyContinue
        $clock = [Diagnostics.Stopwatch]::StartNew()
        do {
            $s = Get-ExactService
            $script:ServiceState = [string]$s.State
            $left = @(Get-CimInstance Win32_Process -Filter ('ProcessId=' + $script:OriginalProcessId) -OperationTimeoutSec 5 -ErrorAction Stop)
            if ($s.State -eq 'Stopped' -and $s.ProcessId -eq 0 -and $left.Count -eq 0) { break }
            if ($clock.Elapsed.TotalSeconds -ge 15) { Stop-Guard 'SERVICE_STOP_TIMEOUT' -Failure }
            Start-Sleep -Milliseconds 200
        } while ($true)
    }
    $stopped = Assert-Stopped $fresh.Current $script:OriginalProcessId
    $script:Phase = 'BEFORE_REGISTER'
    if ((Assert-SingleDesktopUser) -ne $fresh.UserSid) { Stop-Guard 'USER_CHANGED' }
    $current = Get-CurrentPackage
    if ($current.PackageFullName -cne $fresh.Current.PackageFullName) { Stop-Guard 'PACKAGE_CHANGED_DURING_APPLY' }
    $target = Get-StagedCandidate $current
    if ($null -eq $target -or $target.PackageFullName -cne $fresh.Target.PackageFullName) { Stop-Guard 'TARGET_CHANGED_DURING_APPLY' }
    Assert-TargetServiceLayout $target
    $manifest = Get-VerifiedManifest $target
    if ($manifest.Path -ine $fresh.Manifest.Path -or $manifest.Hash -cne $fresh.Manifest.Hash) { Stop-Guard 'MANIFEST_CHANGED' }
    Assert-ProcessGate $current $target $stopped $fresh.UserSid -AfterStop
    $null = Assert-Stopped $current $script:OriginalProcessId
    $script:Phase = 'REGISTER'
    $script:Changed = $true
    Add-AppxPackage -DisableDevelopmentMode -Register $manifest.Path -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    $script:Phase = 'VERIFY'
    if ((Assert-SingleDesktopUser) -ne $fresh.UserSid) { Stop-Guard 'USER_CHANGED' }
    $after = Get-CurrentPackage
    Assert-TrustedPackage $after $target.Publisher
    if ($after.PackageFullName -cne $target.PackageFullName -or
        [version]$after.Version -ne [version]$target.Version) { Stop-Guard 'POST_REGISTER_TARGET_MISMATCH' -Failure }
    $afterManifest = Get-VerifiedManifest $after
    if ($afterManifest.Hash -cne $manifest.Hash) { Stop-Guard 'POST_REGISTER_MANIFEST_MISMATCH' -Failure }
    $script:Phase = 'POST_REGISTER_SERVICE'
    Assert-PostRegisterService $after
    $script:CurrentVersion = ([version]$after.Version).ToString()
    $script:Verdict = 'PASS'; $script:State = 'UPDATED'; $script:ExitCode = 0
}

try {
    Assert-Platform
    Enter-GuardMutex
    Initialize-WtsReader
    $evidence = Get-Preflight
    $script:OriginalState = [string]$evidence.Service.State
    $script:OriginalStartMode = [string]$evidence.Service.StartMode
    $script:OriginalProcessId = [uint32]$evidence.Service.ProcessId
    if ($null -eq $evidence.Target) {
        $script:Verdict = 'PASS'; $script:State = 'NO_ACTION'; $script:ExitCode = 0
    } elseif (-not $Apply.IsPresent) {
        $script:Verdict = 'PASS'; $script:State = 'READY_DRY_RUN'; $script:ExitCode = 0
    } else { Invoke-ApplyRecovery $evidence }
} catch {
    $script:ErrorCategory = 'UNEXPECTED_' + $script:Phase
    $isBlock = $false
    if ($_.Exception.Data.Contains('GuardCategory')) {
        $script:ErrorCategory = [string]$_.Exception.Data['GuardCategory']
        $isBlock = [bool]$_.Exception.Data['GuardBlock']
    }
    if ($script:Changed) {
        $script:Verdict = 'FAIL'; $script:State = 'FAILED_AFTER_CHANGE'; $script:ExitCode = 21
    } elseif ($isBlock) {
        $script:Verdict = 'BLOCK'; $script:State = 'BLOCKED'; $script:ExitCode = 10
    } else {
        $script:Verdict = 'FAIL'; $script:State = 'FAILED_NO_CHANGE'; $script:ExitCode = 20
    }
} finally {
    # No automatic service restart: retaining evidence is the V0.1 failure policy.
    # UPDATED keeps its validated snapshot; supplemental reads are for failure reporting only.
    if ($script:Changed -and $script:State -ne 'UPDATED') {
        try { $script:ServiceState = [string](Get-ExactService).State }
        catch { $script:ServiceState = 'UNKNOWN' }
    }
    if ($script:OwnsMutex) {
        try { $script:Mutex.ReleaseMutex() }
        catch {
            $script:Verdict = 'FAIL'; $script:State = 'MUTEX_RELEASE_FAILED'
            $script:ErrorCategory = 'MUTEX_RELEASE_FAILED'
            if ($script:Changed) { $script:ExitCode = 21 } else { $script:ExitCode = 20 }
        }
    }
    if ($null -ne $script:Mutex) {
        try { $script:Mutex.Dispose() }
        catch {
            $script:Verdict = 'FAIL'; $script:State = 'MUTEX_DISPOSE_FAILED'
            $script:ErrorCategory = 'MUTEX_DISPOSE_FAILED'
            if ($script:Changed) { $script:ExitCode = 21 } else { $script:ExitCode = 20 }
        }
    }
}

$changedText = 'NO'
if ($script:Changed) { $changedText = 'YES' }
# Minimal structured console log; no files, transcript, raw exception or automatic upload.
$record = [ordered]@{
    time = [DateTime]::UtcNow.ToString('o'); phase = $script:Phase
    current_version = $script:CurrentVersion; target_version = $script:TargetVersion
    architecture = $script:Architecture; staged_candidate_count = $script:CandidateCount
    system_changed = $changedText; verdict = $script:Verdict; state = $script:State
    error_category = $script:ErrorCategory; service_state = $script:ServiceState
    original_service_state = $script:OriginalState; original_start_mode = $script:OriginalStartMode
    original_service_pid = $script:OriginalProcessId; exit_code = $script:ExitCode
}
Write-Output ($record | ConvertTo-Json -Compress)
Write-Output ('VERDICT=' + $script:Verdict)
Write-Output ('STATE=' + $script:State)
Write-Output ('SYSTEM_CHANGED=' + $changedText)
Write-Output ('CURRENT_VERSION=' + $script:CurrentVersion)
Write-Output ('TARGET_VERSION=' + $script:TargetVersion)
Write-Output ('EXIT_CODE=' + $script:ExitCode)
Write-Output ('SERVICE_STATE=' + $script:ServiceState)
Write-Output ('ERROR_CATEGORY=' + $script:ErrorCategory)
if ($script:State -eq 'UPDATED') {
    Write-Output 'NEXT=Open Codex manually; verify normal startup and no update arrow.'
} elseif ($script:Changed) {
    Write-Output 'NEXT=Preserve this result. Service was not automatically restarted; manual review is required.'
} elseif ($script:ErrorCategory -match 'PROCESS|HOST|ANCESTOR') {
    Write-Output 'NEXT=Fully exit Codex, then retry from an independent Windows PowerShell 5.1 console.'
}
exit $script:ExitCode
