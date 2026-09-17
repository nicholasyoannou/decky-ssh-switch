#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Mount')]
param(
    [Parameter(ParameterSetName = 'Mount')][switch] $Configure,
    [Parameter(ParameterSetName = 'Unmount')][switch] $Unmount
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Default([string] $Label, [string] $Default) {
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $answer = Read-Host "$Label$suffix"
    if ($answer -eq '') { return $Default }
    return $answer
}

function Test-AddressInput([string] $Address) {
    # SSH Switch lists the Deck's IPv6 addresses, but a mount is a UNC path and
    # a UNC name component cannot hold their colons, so say what works instead.
    if ($Address -match ':') { throw 'SSHFS-Win cannot mount an IPv6 address. Use a hostname such as steamdeck.local, or the IPv4 address shown in SSH Switch.' }
    if ($Address -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$') { throw 'Enter an IPv4 address or hostname, without a URL or username.' }
}

function Test-ConnectionInput([string] $Address, [string] $Port, [string] $Username, [string] $RemoteFolder) {
    Test-AddressInput $Address
    if ($Port -notmatch '^[0-9]{1,5}$' -or [int]$Port -lt 1 -or [int]$Port -gt 65535) { throw 'Port must be between 1 and 65535.' }
    if ($Username -cnotmatch '^[a-zA-Z_][a-zA-Z0-9_-]*\$?$') { throw 'Enter the username shown on the Deck.' }
    if (-not $RemoteFolder.StartsWith('/') -or $RemoteFolder -match '[\x00-\x1f\\:*?"<>|]') { throw 'Remote folder must be an absolute path without Windows-reserved characters.' }
}

function ConvertTo-NativeArgument([string] $Value) {
    # Windows CRT quoting for ProcessStartInfo on Windows PowerShell 5.1.
    # No shell evaluates these arguments.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Find-Sshfs {
    foreach ($base in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) {
            $candidate = Join-Path $base 'SSHFS-Win\bin\sshfs.exe'
            if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $candidate) 'ssh.exe') -PathType Leaf)) { return $candidate }
        }
    }
    return $null
}

function Test-WinFspInstalled {
    $library = if ([Environment]::Is64BitOperatingSystem) { 'bin\winfsp-x64.dll' } else { 'bin\winfsp-x86.dll' }
    foreach ($key in @('HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\WinFsp', 'HKEY_LOCAL_MACHINE\SOFTWARE\WinFsp')) {
        $directory = [Microsoft.Win32.Registry]::GetValue($key, 'InstallDir', $null)
        if ($directory -and (Test-Path -LiteralPath (Join-Path $directory $library) -PathType Leaf)) { return $true }
    }
    return $false
}

function Invoke-DependencyInstall([ValidateSet('WinFsp.WinFsp', 'SSHFS-Win.SSHFS-Win')][string] $Id) {
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'WinGet is missing. Install Microsoft App Installer from the Microsoft Store, then reopen mount-windows.cmd.' }
    Write-Host "Installing $Id... Approve the Windows administrator prompt if it appears."
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $winget.Source
    $start.Arguments = (@('install', '--id', $Id, '--exact', '--source', 'winget',
        '--silent', '--no-upgrade', '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity') | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    # WinGet handles installer elevation; the mount stays in the normal user's
    # session so its drive is visible in File Explorer. Never request a reboot.
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [Console]::Write($output.GetAwaiter().GetResult())
        [Console]::Error.Write($errors.GetAwaiter().GetResult())
        return $process.ExitCode
    }
    finally { $process.Dispose() }
}

function Initialize-MountDependencies {
    if (-not (Test-WinFspInstalled)) {
        $code = Invoke-DependencyInstall 'WinFsp.WinFsp'
        if ($code -ne 0) { throw "WinFsp setup did not complete (WinGet exit code $code). Follow the installer message above, then reopen mount-windows.cmd." }
        if (-not (Test-WinFspInstalled)) { throw 'WinFsp is still unavailable. Restart Windows if the installer requested it, then reopen mount-windows.cmd.' }
    }
    $sshfs = Find-Sshfs
    if (-not $sshfs) {
        $code = Invoke-DependencyInstall 'SSHFS-Win.SSHFS-Win'
        if ($code -ne 0) { throw "SSHFS-Win setup did not complete (WinGet exit code $code). Follow the installer message above, then reopen mount-windows.cmd." }
        $sshfs = Find-Sshfs
        if (-not $sshfs) { throw 'SSHFS-Win is still unavailable. Repair its installation in Windows Settings, then reopen mount-windows.cmd.' }
    }
    return $sshfs
}

function Read-YesNo([string] $Label, [bool] $Default) {
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = (Read-Host "$Label [$hint]").Trim()
        if ($answer -eq '') { return $Default }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Host 'Enter yes or no.'
    }
}

function Read-Mount([string] $Name, [string] $RemoteFolder, [string] $DefaultDrive) {
    $drive = (Read-Default "$Name drive letter" $DefaultDrive).Trim().TrimEnd(':').ToUpperInvariant()
    return [pscustomobject]@{ Name = $Name; RemoteFolder = $RemoteFolder; Drive = $drive }
}

function Read-MountSettings {
    Write-Host 'On your Deck, enable SSH and open SSH Switch > Connect from computer.'
    # Checked here so a bad address fails at its own prompt, not after the rest.
    $address = Read-Default 'Address' 'steamdeck.local'
    Test-AddressInput $address
    $port = Read-Default 'Port' '22'
    $username = Read-Default 'Username' 'deck'
    $separate = Read-YesNo 'Create separate Home, SD card and Root drives?' $false
    $mounts = @()
    if ($separate) {
        $remote = Read-Default 'Home folder' "/home/$username"
        $mounts += Read-Mount 'Home' $remote 'X'
        $sd = Read-Default 'SD card folder (blank to skip)' ''
        if ($sd) { $mounts += Read-Mount 'SD card' $sd 'Y' }
        $mounts += Read-Mount 'Root' '/' 'Z'
    } else {
        # One drive holds the whole Deck, so the home folder and the SD card are
        # both reachable from it without mapping a letter to each.
        $remote = Read-Default 'Remote folder' '/'
        $mounts += Read-Mount 'Steam Deck' $remote 'S'
    }
    return [pscustomobject]@{
        Version = 1; Address = $address; Port = $port; Username = $username
        Mounts = $mounts; Credential = $null
    }
}

function Test-MountSettings($Settings) {
    if ($Settings.Version -ne 1 -or @($Settings.Mounts).Count -lt 1 -or @($Settings.Mounts).Count -gt 3) {
        throw 'Invalid mount settings.'
    }
    $letters = @()
    foreach ($mount in $Settings.Mounts) {
        Test-ConnectionInput $Settings.Address $Settings.Port $Settings.Username $mount.RemoteFolder
        if ($mount.Drive -cnotmatch '^[D-Z]$') { throw 'Choose a drive letter from D to Z.' }
        if ($letters -contains $mount.Drive) { throw 'Choose a different letter for each drive.' }
        $letters += $mount.Drive
        if ($mount.Name -notin @('Steam Deck', 'Home', 'SD card', 'Root')) { throw 'Invalid drive name.' }
    }
}

function Get-MountPath($Settings, $Mount) {
    $server = $Settings.Username + '@' + $Settings.Address
    if ([int]$Settings.Port -ne 22) { $server += '!' + ([int]$Settings.Port).ToString() }
    $path = '\\sshfs.r\' + $server
    $folder = $Mount.RemoteFolder.Trim('/').Replace('/', '\')
    if ($folder) { $path += '\' + $folder }
    return $path
}

function Get-SettingsPath {
    return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SSH Switch\mount-windows.xml'
}

function Import-MountSettings([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $settings = Import-Clixml -LiteralPath $Path
        Test-MountSettings $settings
        if ($settings.Credential -isnot [Management.Automation.PSCredential] -or
            $settings.Credential.UserName -cne $settings.Username -or $settings.Credential.Password.Length -eq 0) {
            throw 'Invalid saved credential.'
        }
        return $settings
    } catch {
        throw "Cannot read saved settings for this Windows account. Run mount-windows.cmd -Configure to set up again."
    }
}

function Save-DataFile($Data, [string] $Path) {
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $Data | Export-Clixml -LiteralPath $temporary -Depth 5 -Encoding UTF8
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Save-MountSettings($Settings, [string] $Path) {
    # Export-Clixml encrypts PSCredential with Windows DPAPI for this account/PC.
    Save-DataFile $Settings $Path
}

function Get-MountRecordPath {
    return Join-Path (Split-Path -Parent (Get-SettingsPath)) 'mounted-windows.xml'
}

function Import-MountRecord {
    $path = Get-MountRecordPath
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ Version = 1; Mounts = @() } }
    try {
        $record = Import-Clixml -LiteralPath $path
        if ($record.Version -ne 1 -or @($record.Mounts).Count -gt 23) { throw 'Invalid mount record.' }
        $letters = @()
        foreach ($mount in $record.Mounts) {
            if ($mount.Drive -cnotmatch '^[D-Z]$' -or $letters -contains $mount.Drive -or
                $mount.Target -cnotmatch '^\\\\sshfs\.r\\([^@\\]+)@([^!\\]+)(?:!([0-9]+))?(\\.*)?$') {
                throw 'Invalid recorded drive.'
            }
            $username, $address, $port, $folder = $Matches[1], $Matches[2], $Matches[3], $Matches[4]
            if (-not $port) { $port = '22' }
            $remote = if ($folder) { $folder.Replace('\', '/') } else { '/' }
            Test-ConnectionInput $address $port $username $remote
            $letters += $mount.Drive
        }
        return $record
    } catch {
        throw "Cannot read the mount record at $path. Disconnect the drives in File Explorer, then delete that file and run mount-windows.cmd again."
    }
}

function Save-MountedDrive([string] $Letter, [string] $Target) {
    $record = Import-MountRecord
    $record.Mounts = @($record.Mounts | Where-Object { $_.Drive -cne $Letter }) + @(
        [pscustomobject]@{ Drive = $Letter; Target = $Target }
    )
    # Always record successful mounts, even when saving settings was declined.
    # This file contains only drive letters and destinations, never credentials.
    Save-DataFile $record (Get-MountRecordPath)
}

function Get-DriveTarget([string] $Letter) {
    $drive = Get-PSDrive -Name $Letter -ErrorAction SilentlyContinue
    if ($drive) {
        if ($drive.DisplayRoot) { return $drive.DisplayRoot }
        return $drive.Root
    }
    # Disconnected persistent mappings may not appear in Get-PSDrive.
    $remembered = Get-ItemProperty -LiteralPath "HKCU:\Network\$Letter" -ErrorAction SilentlyContinue
    if ($remembered) { return $remembered.RemotePath }
    if ([IO.DriveInfo]::GetDrives().Name -contains "${Letter}:\") { return "${Letter}:\" }
    return $null
}

function Connect-Mounts($Settings) {
    Test-MountSettings $Settings
    $null = Import-MountRecord
    # Check every letter before making any changes. Never replace other drives.
    foreach ($mount in $Settings.Mounts) {
        $target = Get-DriveTarget $mount.Drive
        $path = Get-MountPath $Settings $mount
        if ($target -and $target -cne $path) {
            throw "$($mount.Drive): is already in use. Run mount-windows.cmd -Configure and choose another letter."
        }
    }
    foreach ($mount in $Settings.Mounts) {
        $letter = $mount.Drive
        $path = Get-MountPath $Settings $mount
        $target = Get-DriveTarget $letter
        if ($target -and $target -cne $path) { throw "${letter}: is already in use." }
        if ($target -and (Test-Path -LiteralPath "${letter}:\" -ErrorAction SilentlyContinue)) {
            Save-MountedDrive $letter $path
            Write-Host "$($mount.Name) is already mounted at ${letter}:\"
            continue
        }
        try {
            # Reconnect only a disconnected mapping to this exact destination.
            if ($target) {
                & net.exe use "${letter}:" /delete /y | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Could not disconnect the previous mapping (Windows exit code $LASTEXITCODE)." }
            }
            $null = New-PSDrive -Name $letter -PSProvider FileSystem -Root $path `
                -Credential $Settings.Credential -Persist -Scope Global -ErrorAction Stop
        } catch {
            throw "Could not mount $($mount.Name) at ${letter}: $($_.Exception.Message) Check the address, password and folder. To change saved settings, run mount-windows.cmd -Configure."
        }
        try { Save-MountedDrive $letter $path }
        catch { throw "${letter}: mounted, but its location could not be saved for unmounting. Disconnect it in File Explorer. $($_.Exception.Message)" }
        Write-Host "$($mount.Name) mounted at ${letter}:\"
    }
}

function Disconnect-NetworkDrive([string] $Letter) {
    if (-not ('SshSwitch.Network' -as [type])) {
        Add-Type @'
using System.Runtime.InteropServices;
namespace SshSwitch {
    public static class Network {
        [DllImport("mpr.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern int WNetCancelConnection2W(string name, int flags, bool force);
    }
}
'@
    }
    # Remove the remembered mapping too, so Windows won't restore it at logon.
    # Refuse to force a disconnect while files are open.
    $code = [SshSwitch.Network]::WNetCancelConnection2W("${Letter}:", 1, $false)
    if ($code -ne 0) {
        $message = (New-Object ComponentModel.Win32Exception($code)).Message
        throw "$message (Windows error $code). Close files and windows using ${Letter}: and try again."
    }
    Remove-PSDrive -Name $Letter -ErrorAction SilentlyContinue
}

function Unmount-SteamDeck {
    $record = Import-MountRecord
    if (@($record.Mounts).Count -eq 0) { Write-Host 'No recorded drives to unmount.'; return }
    $failed = $false
    foreach ($mount in @($record.Mounts)) {
        $letter = $mount.Drive
        $target = Get-DriveTarget $letter
        if (-not $target) {
            Write-Host "${letter}: is already disconnected."
        } elseif ($target -cne $mount.Target) {
            Write-Host "Skipping ${letter}: it now points somewhere else."
        } else {
            try { Disconnect-NetworkDrive $letter }
            catch {
                Write-Warning "Could not unmount ${letter}: $($_.Exception.Message)"
                $failed = $true
                continue
            }
            Write-Host "${letter}: unmounted."
        }
        $record.Mounts = @($record.Mounts | Where-Object { $_.Drive -cne $letter })
        Save-DataFile $record (Get-MountRecordPath)
    }
    if ($failed) { throw 'Some drives could not be unmounted. Close files using them and run unmount-windows.cmd again.' }
    Write-Host 'Saved connection settings are kept. Run mount-windows.cmd to reconnect.'
}

function Mount-SteamDeck([switch] $Configure) {
    if ($env:OS -ne 'Windows_NT') { throw 'Use mount-linux.sh or mount-macos.sh on this computer.' }
    $null = Initialize-MountDependencies
    $settingsPath = Get-SettingsPath
    $settings = $null
    $save = $false
    try {
        if (-not $Configure) { $settings = Import-MountSettings $settingsPath }
        if ($settings) {
            Write-Host "Using saved settings for $($settings.Address)."
        } else {
            $settings = Read-MountSettings
            Test-MountSettings $settings
            $password = Read-Host 'Deck account password' -AsSecureString
            if ($password.Length -eq 0) { $password.Dispose(); throw 'The password cannot be blank.' }
            $settings.Credential = New-Object Management.Automation.PSCredential($settings.Username, $password)
            $save = Read-YesNo 'Save settings and password for automatic mounting next time?' $true
        }
        Connect-Mounts $settings
        if ($save) {
            Save-MountSettings $settings $settingsPath
            Write-Host "Settings saved to $settingsPath (password encrypted for your Windows account)."
        } elseif ($Configure -and (Test-Path -LiteralPath $settingsPath)) {
            # Choosing not to save during reconfiguration also forgets old data.
            Remove-Item -LiteralPath $settingsPath
        }
        Write-Host 'You can close this window. To disconnect these drives later, run unmount-windows.cmd.'
    } finally {
        if ($settings -and $settings.Credential) { $settings.Credential.Password.Dispose() }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $lock = $null
    try {
        # Serialize launcher runs so mount/unmount cannot overwrite each other's record.
        $directory = Split-Path -Parent (Get-SettingsPath)
        $null = [IO.Directory]::CreateDirectory($directory)
        try { $lock = [IO.File]::Open((Join-Path $directory 'mount-windows.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { throw 'Another mount or unmount helper is running, or its data folder is not writable.' }
        if ($Unmount) { Unmount-SteamDeck }
        else { Mount-SteamDeck -Configure:$Configure }
    }
    catch { [Console]::Error.WriteLine('SSH Switch: ' + $_.Exception.Message); exit 1 }
    finally { if ($lock) { $lock.Dispose() } }
}
