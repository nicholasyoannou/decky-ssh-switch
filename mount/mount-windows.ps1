#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Default([string] $Label, [string] $Default) {
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $answer = Read-Host "$Label$suffix"
    if ($answer -eq '') { return $Default }
    return $answer
}

function Test-ConnectionInput([string] $Address, [string] $Port, [string] $Username, [string] $RemoteFolder) {
    if ($Address -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$') { throw 'Enter an IPv4 address or hostname, without a URL or username.' }
    if ($Port -notmatch '^[0-9]{1,5}$' -or [int]$Port -lt 1 -or [int]$Port -gt 65535) { throw 'Port must be between 1 and 65535.' }
    if ($Username -cnotmatch '^[a-zA-Z_][a-zA-Z0-9_-]*\$?$') { throw 'Enter the username shown on the Deck.' }
    if (-not $RemoteFolder.StartsWith('/') -or $RemoteFolder -match '[\x00\r\n]') { throw 'Remote folder must be an absolute path.' }
}

function ConvertTo-NativeArgument([string] $Value) {
    # Windows CRT quoting for ProcessStartInfo on Windows PowerShell 5.1.
    # No shell evaluates these arguments.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function ConvertTo-SshPath([string] $Value) {
    # Cygwin OpenSSH accepts forward-slash Windows paths; SSH's option parser
    # needs its own quotes when a path contains spaces.
    if ($Value -match '["\r\n,]') { throw 'SSHFS cannot use an installation or profile path containing a quote, comma, or newline.' }
    return '"' + $Value.Replace('\', '/') + '"'
}

function Get-MountArguments([string] $Address, [string] $Port, [string] $Username, [string] $RemoteFolder,
    [string] $Drive, [string] $KnownHosts) {
    Test-ConnectionInput $Address $Port $Username $RemoteFolder
    if ($Drive -notmatch '^[D-Z]:$') { throw 'Choose a drive letter from D to Z.' }
    return @(
        "${Username}@${Address}:$RemoteFolder", $Drive, '-p', ([int]$Port).ToString(), '-f',
        '-o', 'ssh_command=ssh.exe -F /dev/null',
        '-o', ('UserKnownHostsFile=' + (ConvertTo-SshPath $KnownHosts)),
        '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'StrictHostKeyChecking=yes',
        '-o', 'HostKeyAlgorithms=ssh-ed25519', '-o', 'PreferredAuthentications=password',
        '-o', 'password_stdin', '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
        '-o', 'sshfs_sync', '-o', 'idmap=user', '-o', 'umask=077', '-o', 'volname=Steam Deck'
    )
}

function Get-ScannedKey([string[]] $Lines) {
    $keys = @($Lines | Where-Object { $_ -cmatch '^\S+ ssh-ed25519 [A-Za-z0-9+/]+={0,2}$' } | Select-Object -Unique)
    if ($keys.Count -ne 1) { throw 'Could not read one Ed25519 host key. Check the address, port, and that SSH is enabled.' }
    $key = $keys[0]
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash([Convert]::FromBase64String(($key -split ' ')[2])) }
    finally { $sha.Dispose() }
    return @{ Line = $key; Fingerprint = 'SHA256:' + [Convert]::ToBase64String($digest).TrimEnd('=') }
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

function Mount-SteamDeck {
    if ($env:OS -ne 'Windows_NT') { throw 'Use mount-linux.sh or mount-macos.sh on this computer.' }
    $sshfs = Initialize-MountDependencies
    $ssh = Join-Path (Split-Path -Parent $sshfs) 'ssh.exe'
    if (-not (Test-Path -LiteralPath $ssh -PathType Leaf)) { throw 'Reinstall SSHFS-Win: its bundled SSH client is missing.' }

    Write-Host 'On your Deck, enable SSH and open SSH Switch > Connect from computer.'
    $address = Read-Default 'Address' ''
    $port = Read-Default 'Port' '22'
    $username = Read-Default 'Username' 'deck'
    $remote = Read-Default 'Remote folder' "/home/$username"
    Test-ConnectionInput $address $port $username $remote
    $drive = (Read-Default 'Drive letter' 'S').TrimEnd(':').ToUpperInvariant() + ':'
    if ($drive -notmatch '^[D-Z]:$') { throw 'Choose a drive letter from D to Z.' }
    $letter = $drive.Substring(0, 1)
    # Get-PSDrive also catches disconnected mappings and custom PowerShell drives.
    if ((Get-PSDrive -Name $letter -ErrorAction SilentlyContinue) -or
        ([IO.DriveInfo]::GetDrives().Name -contains "$drive\")) { throw "$drive is already in use. Choose another letter." }

    # Only this public host key is written to disk. The password travels solely
    # over the child process's stdin, never in arguments or a settings file.
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('ssh-switch-' + [guid]::NewGuid().ToString('N'))
    $process = $null
    $password = $null
    try {
        $null = [IO.Directory]::CreateDirectory($temporary)
        $knownHosts = Join-Path $temporary 'known_hosts'
        # Probe with the bundled client, with all authentication disabled. Some
        # Windows ssh-keyscan versions cannot negotiate with current SteamOS.
        # This key is trusted only after the user compares it with the Deck.
        $scanInfo = New-Object Diagnostics.ProcessStartInfo
        $scanInfo.FileName = $ssh
        $scanArguments = @('-F', '/dev/null', '-T', '-p', ([int]$port).ToString(),
            '-o', ('UserKnownHostsFile=' + (ConvertTo-SshPath $knownHosts)),
            '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'StrictHostKeyChecking=accept-new',
            '-o', 'HashKnownHosts=no', '-o', 'HostKeyAlgorithms=ssh-ed25519',
            '-o', 'PreferredAuthentications=none', '-o', 'BatchMode=yes',
            '-o', 'ConnectTimeout=10', '-s', "${username}@$address", 'sftp')
        $scanInfo.Arguments = ($scanArguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
        $scanInfo.UseShellExecute = $false
        $scanInfo.CreateNoWindow = $true
        $scanInfo.RedirectStandardInput = $true
        $scanInfo.RedirectStandardOutput = $true
        $scanInfo.RedirectStandardError = $true
        $scan = [Diagnostics.Process]::Start($scanInfo)
        try {
            $scan.StandardInput.Close()
            $scanOutput = $scan.StandardOutput.ReadToEndAsync()
            $scanError = $scan.StandardError.ReadToEndAsync()
            if (-not $scan.WaitForExit(15000)) { throw 'The Deck did not respond. Check its address and that SSH is enabled.' }
            $null = $scanOutput.GetAwaiter().GetResult()
            $null = $scanError.GetAwaiter().GetResult()
        } finally {
            if (-not $scan.HasExited) { $scan.Kill(); $scan.WaitForExit() }
            $scan.Dispose()
        }
        if (-not (Test-Path -LiteralPath $knownHosts)) { throw 'Could not read the Deck host key. Check its address, port, and that SSH is enabled.' }
        $key = Get-ScannedKey ([IO.File]::ReadAllLines($knownHosts))
        Write-Host "SSH fingerprint (Ed25519): $($key.Fingerprint)"
        if ((Read-Host 'Does this exactly match the fingerprint on your Deck? Type yes to connect') -cne 'yes') { throw 'Connection cancelled.' }
        $arguments = Get-MountArguments $address $port $username $remote $drive $knownHosts
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $sshfs
        $start.Arguments = ($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        # SSHFS changes its working directory and does not parse quoted commands.
        # Prepend only this child's PATH so it finds the bundled client even when
        # the installation path contains spaces.
        $start.WorkingDirectory = Split-Path -Parent $sshfs
        $start.EnvironmentVariables['PATH'] = $start.WorkingDirectory + ';' + $env:PATH
        $password = Read-Host 'Deck account password' -AsSecureString
        if ($password.Length -eq 0) { throw 'The password cannot be blank.' }
        $process = [Diagnostics.Process]::Start($start)
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
        $bytes = $null
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) + "`n")
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $process.StandardInput.BaseStream.Flush()
        } finally {
            if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
            $password.Dispose()
            $password = $null
        }
        $process.StandardInput.Close()
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not $process.HasExited -and -not [IO.Directory]::Exists("$drive\") -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
        if ($process.HasExited -or -not [IO.Directory]::Exists("$drive\")) { throw 'Mount failed. Check the password and remote folder; see the SSHFS message above.' }
        Write-Host "Mounted at $drive\ - keep this window open."
        $null = Read-Host 'Close files on the drive, then press Enter to disconnect'
    } finally {
        # This foreground SSHFS instance owns the drive. Terminating only our
        # retained process releases it; sshfs_sync prevents deferred write caching.
        if ($process) {
            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            $process.Dispose()
        }
        if ($password) { $password.Dispose() }
        if (Test-Path -LiteralPath $temporary) {
            # Delete only our known file and then the empty temporary directory.
            Remove-Item -LiteralPath (Join-Path $temporary 'known_hosts') -ErrorAction SilentlyContinue
            [IO.Directory]::Delete($temporary)
        }
    }
    Write-Host 'Disconnected.'
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Mount-SteamDeck }
    catch { [Console]::Error.WriteLine('SSH Switch: ' + $_.Exception.Message); exit 1 }
}
