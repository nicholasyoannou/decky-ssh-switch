param([string] $Python)
. "$PSScriptRoot/../mount/mount-windows.ps1"

function Assert-True([bool] $Value, [string] $Message) { if (-not $Value) { throw $Message } }
function Assert-Throws([scriptblock] $Action) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    Assert-True $failed 'Expected invalid input to fail.'
}
function New-TestSecret([string] $Value) {
    $secret = New-Object Security.SecureString
    foreach ($character in $Value.ToCharArray()) { $secret.AppendChar($character) }
    return $secret
}

Test-ConnectionInput '192.0.2.10' '02222' 'deck' '/run/media/deck/My SD'
Assert-Throws { Test-ConnectionInput '-oProxyCommand=bad' '22' 'deck' '/home/deck' }
Assert-Throws { Test-ConnectionInput 'host;bad' '22' 'deck' '/home/deck' }
Assert-Throws { Test-ConnectionInput 'host' '65536' 'deck' '/home/deck' }
Assert-Throws { Test-ConnectionInput 'host' '0' 'deck' '/home/deck' }
Assert-Throws { Test-ConnectionInput 'host' '22' 'deck@other' '/home/deck' }
Assert-Throws { Test-ConnectionInput 'host' '22' 'deck' 'relative' }
Assert-Throws { Test-ConnectionInput 'host' '22' 'deck' '/ambiguous\path' }

# Verify the installer's native argument quoting with a real child process.
$values = @('', 'space value', 'quote"value', 'C:\space dir\', '\\"', '$(NEVER_RUN);&')
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = $Python
$start.Arguments = (@('-c', 'import json,sys; print(json.dumps(sys.argv[1:]))') + $values | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$child = [Diagnostics.Process]::Start($start)
try {
    $actual = $child.StandardOutput.ReadToEnd() | ConvertFrom-Json
    $child.WaitForExit()
    Assert-True ($child.ExitCode -eq 0) 'Child failed.'
    Assert-True ($actual.Count -eq $values.Count) 'Argument count changed.'
    for ($i = 0; $i -lt $values.Count; $i++) { Assert-True ($actual[$i] -ceq $values[$i]) "Argument $i changed." }
} finally { $child.Dispose() }

function Set-Answers([string[]] $Answers) {
    $script:answers = New-Object 'Collections.Generic.Queue[string]'
    foreach ($answer in $Answers) { $script:answers.Enqueue($answer) }
    $script:prompts = New-Object 'Collections.Generic.List[string]'
}
function Read-Host([string] $Prompt, [switch] $AsSecureString) {
    $script:prompts.Add($Prompt)
    if ($script:answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
    $answer = $script:answers.Dequeue()
    if ($AsSecureString) {
        $secret = New-Object Security.SecureString
        foreach ($character in $answer.ToCharArray()) { $secret.AppendChar($character) }
        return $secret
    }
    return $answer
}

# Pressing Enter throughout creates exactly one drive at S: on steamdeck.
Set-Answers @('', '', '', '', '', '')
$single = Read-MountSettings
Test-MountSettings $single
Assert-True ($single.Address -ceq 'steamdeck') 'Default hostname changed.'
Assert-True ($single.Mounts.Count -eq 1) 'Extra drives must be opt-in.'
Assert-True ($single.Mounts[0].Drive -ceq 'S') 'Default drive changed.'
Assert-True ((Get-MountPath $single $single.Mounts[0]) -ceq '\\sshfs.r\deck@steamdeck\home\deck') 'Incorrect single-drive path.'
Set-Answers @('')
Assert-True (Read-YesNo 'Save?' $true) 'Saving must default to Yes.'
Set-Answers @('invalid', 'NO')
Assert-True (-not (Read-YesNo 'Save?' $true)) 'Explicit No must be accepted after invalid input.'

Set-Answers @('192.0.2.10', '02222', 'deck', 'yes', '', '', '/run/media/deck/My SD & $(literal)', '', '')
$separate = Read-MountSettings
Test-MountSettings $separate
Assert-True ($separate.Mounts.Count -eq 3) 'Separate setup must include all three drives.'
Assert-True (($separate.Mounts.Drive -join ',') -ceq 'X,Y,Z') 'Incorrect separate-drive defaults.'
Assert-True ((Get-MountPath $separate $separate.Mounts[1]) -ceq '\\sshfs.r\deck@192.0.2.10!2222\run\media\deck\My SD & $(literal)') 'SD path must be literal, with custom port.'
Assert-True ((Get-MountPath $separate $separate.Mounts[2]) -ceq '\\sshfs.r\deck@192.0.2.10!2222') 'Root must map the filesystem root.'
Set-Answers @('', '', '', 'y', '', '', '', '')
$withoutSd = Read-MountSettings
Assert-True (($withoutSd.Mounts.Name -join ',') -ceq 'Home,Root') 'Blank SD path must skip that drive.'
$withoutSd.Mounts[1].Drive = 'X'
Assert-Throws { Test-MountSettings $withoutSd }
$withoutSd.Mounts[1].Drive = 'C'
Assert-Throws { Test-MountSettings $withoutSd }

# Real DPAPI serialization: settings and punctuation-heavy password survive,
# while plaintext and simple encodings never appear in the saved file.
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('ssh-switch-settings-' + [guid]::NewGuid().ToString('N'))
$path = Join-Path $temporary 'mount-windows.xml'
$synthetic = 'test space & $() % ! '' " ' + [char]0x00E9
$secret = New-TestSecret $synthetic
$single.Credential = New-Object Management.Automation.PSCredential('deck', $secret)
try {
    Save-MountSettings $single $path
    $xml = [IO.File]::ReadAllText($path)
    Assert-True (-not $xml.Contains($synthetic)) 'Password was saved in plaintext.'
    Assert-True (-not $xml.Contains([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($synthetic)))) 'Password was merely base64 encoded.'
    $loaded = Import-MountSettings $path
    try {
        Assert-True ($loaded.Credential.GetNetworkCredential().Password -ceq $synthetic) 'Encrypted password did not round-trip.'
        Assert-True ((Get-MountPath $loaded $loaded.Mounts[0]) -ceq (Get-MountPath $single $single.Mounts[0])) 'Saved mount changed.'
    } finally { $loaded.Credential.Password.Dispose() }
    Save-MountSettings $separate $path
    Assert-Throws { Import-MountSettings $path } # missing credential
    [IO.File]::WriteAllText($path, 'invalid data')
    Assert-Throws { Import-MountSettings $path }
    [IO.File]::Delete($path)
    Assert-True ($null -eq (Import-MountSettings $path)) 'Missing settings should start setup.'
} finally {
    $secret.Dispose()
    if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    [IO.Directory]::Delete($temporary)
}

# Mock only OS mapping operations; exercise the real preflight/reuse/reconnect
# logic without altering the developer's actual drives or network.
& {
    $script:targets = @{}
    $script:connected = @{}
    $script:mapped = New-Object 'Collections.Generic.List[string]'
    $script:deleted = New-Object 'Collections.Generic.List[string]'
    $script:failMount = $false
    function Get-DriveTarget([string] $Letter) { return $script:targets[$Letter] }
    function Test-Path([string] $LiteralPath) { return $script:connected[$LiteralPath.Substring(0, 1)] -eq $true }
    function net.exe {
        Assert-True ($args[0] -eq 'use' -and $args[2] -eq '/delete') 'Unexpected net operation.'
        $script:deleted.Add($args[1])
        $global:LASTEXITCODE = 0
    }
    function New-PSDrive {
        [CmdletBinding()]
        param($Name, $PSProvider, $Root, $Credential, [switch] $Persist, $Scope)
        Assert-True ($Persist -and $Scope -eq 'Global' -and $PSProvider -eq 'FileSystem') 'Drive must outlive the script.'
        Assert-True ($Credential -is [Management.Automation.PSCredential]) 'Use a credential object, not a command-line password.'
        if ($script:failMount) { throw 'Synthetic network failure' }
        $script:mapped.Add($Name)
        $script:targets[$Name] = $Root
        $script:connected[$Name] = $true
    }
    $credential = New-Object Management.Automation.PSCredential('deck', (New-TestSecret 'synthetic'))
    $separate.Credential = $credential
    try {
        $script:targets['Z'] = '\\unrelated\share'
        Assert-Throws { Connect-Mounts $separate }
        Assert-True ($script:mapped.Count -eq 0 -and $script:deleted.Count -eq 0) 'Check all letters before any changes.'
        $script:targets.Clear()
        Connect-Mounts $separate
        Assert-True (($script:mapped -join ',') -eq 'X,Y,Z') 'All requested drives should mount.'
        $script:mapped.Clear()
        Connect-Mounts $separate
        Assert-True ($script:mapped.Count -eq 0 -and $script:deleted.Count -eq 0) 'Repeat runs must reuse active drives.'
        $script:connected['Y'] = $false
        Connect-Mounts $separate
        Assert-True (($script:mapped -join ',') -eq 'Y' -and ($script:deleted -join ',') -eq 'Y:') 'Only the disconnected matching drive should reconnect.'
        $script:targets.Clear()
        $script:failMount = $true
        Assert-Throws { Connect-Mounts $separate }
    } finally { $credential.Password.Dispose() }
}

# Full first-run/saved-run flow with a real encrypted data file and mocked mounts.
& {
    $script:settingsFile = Join-Path $temporary 'mount-windows.xml'
    $script:mountCalls = 0
    $script:mountFails = $false
    function Get-SettingsPath { return $script:settingsFile }
    function Initialize-MountDependencies { return 'installed' }
    function Connect-Mounts($Settings) {
        Test-MountSettings $Settings
        Assert-True ($Settings.Credential.GetNetworkCredential().Password -ceq 'synthetic') 'Incorrect saved credential.'
        if ($script:mountFails) { throw 'Synthetic mount failure' }
        $script:mountCalls++
    }
    try {
        Set-Answers @('', '', '', '', '', '', 'synthetic', '')
        Mount-SteamDeck
        Assert-True (Test-Path -LiteralPath $script:settingsFile) 'Default Yes must save a data file.'
        Assert-True ($script:answers.Count -eq 0) 'Setup should consume the expected prompts.'
        Set-Answers @()
        Mount-SteamDeck
        Assert-True ($script:prompts.Count -eq 0 -and $script:mountCalls -eq 2) 'Saved runs must mount with no prompts.'
        Set-Answers @('', '', '', '', '', '', 'synthetic', 'n')
        Mount-SteamDeck -Configure
        Assert-True (-not (Test-Path -LiteralPath $script:settingsFile)) 'Reconfiguring without saving must forget previous data.'
        Set-Answers @('', '', '', '', '', '', 'synthetic', 'n')
        Mount-SteamDeck
        Assert-True (-not (Test-Path -LiteralPath $script:settingsFile)) 'No must not create a file.'
        Set-Answers @('', '', '', '', '', '', 'synthetic', '')
        $script:mountFails = $true
        Assert-Throws { Mount-SteamDeck }
        Assert-True (-not (Test-Path -LiteralPath $script:settingsFile)) 'Failed setup must not be saved.'
        Set-Answers @('', '', '', '', '', '', '')
        Assert-Throws { Mount-SteamDeck }
    } finally {
        if ([IO.File]::Exists($script:settingsFile)) { [IO.File]::Delete($script:settingsFile) }
        if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary) }
    }
}

# No packages are installed by these tests. Exercise setup decisions, including
# rechecking an installer's success instead of trusting only its exit code.
$script:installs = New-Object 'Collections.Generic.List[string]'
function Reset-Dependencies([bool] $Fsp, [bool] $Sshfs, [int] $ExitCode = 0, [bool] $NoEffect = $false) {
    $script:hasFsp = $Fsp
    $script:hasSshfs = $Sshfs
    $script:installerExitCode = $ExitCode
    $script:installerNoEffect = $NoEffect
    $script:installs.Clear()
}
function Test-WinFspInstalled { return $script:hasFsp }
function Find-Sshfs { if ($script:hasSshfs) { return 'C:\Program Files\SSHFS-Win\bin\sshfs.exe' }; return $null }
function Invoke-DependencyInstall([string] $Id) {
    $script:installs.Add($Id)
    if ($script:installerExitCode -eq 0 -and -not $script:installerNoEffect) {
        if ($Id -eq 'WinFsp.WinFsp') { $script:hasFsp = $true } else { $script:hasSshfs = $true }
    }
    return $script:installerExitCode
}
Reset-Dependencies $false $false
$result = Initialize-MountDependencies
Assert-True ($result -ceq 'C:\Program Files\SSHFS-Win\bin\sshfs.exe') 'Setup did not return the installed program.'
Assert-True (($script:installs -join ',') -ceq 'WinFsp.WinFsp,SSHFS-Win.SSHFS-Win') 'Dependencies must install in order.'
Reset-Dependencies $true $true
$null = Initialize-MountDependencies
Assert-True ($script:installs.Count -eq 0) 'Already installed dependencies must not be changed.'
Reset-Dependencies $true $false
$null = Initialize-MountDependencies
Assert-True (($script:installs -join ',') -ceq 'SSHFS-Win.SSHFS-Win') 'Only SSHFS-Win should be installed.'
Reset-Dependencies $false $true
$null = Initialize-MountDependencies
Assert-True (($script:installs -join ',') -ceq 'WinFsp.WinFsp') 'Only WinFsp should be installed.'
Reset-Dependencies $false $false 5
Assert-Throws { Initialize-MountDependencies }
Assert-True ($script:installs.Count -eq 1) 'A failed driver install must stop setup.'
Reset-Dependencies $false $false 0 $true
Assert-Throws { Initialize-MountDependencies }
Assert-True ($script:installs.Count -eq 1) 'A missing driver must stop setup even after exit code zero.'
Reset-Dependencies $true $false 0 $true
Assert-Throws { Initialize-MountDependencies }

Write-Host 'Windows mount checks passed.'
