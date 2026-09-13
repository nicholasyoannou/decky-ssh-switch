param([string] $Python)
. "$PSScriptRoot/../mount/mount-windows.ps1"

function Assert-True([bool] $Value, [string] $Message) { if (-not $Value) { throw $Message } }
function Assert-Throws([scriptblock] $Action) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    Assert-True $failed 'Expected invalid input to fail.'
}

Test-ConnectionInput '192.0.2.10' '02222' 'deck' '/run/media/deck/My SD'
Assert-Throws { Test-ConnectionInput '-oProxyCommand=bad' '22' 'deck' '/home/deck' }
Assert-Throws { Test-ConnectionInput 'host;bad' '22' 'deck' '/home/deck' }
Assert-Throws { Test-ConnectionInput 'host' '65536' 'deck' '/home/deck' }
Assert-Throws { Test-ConnectionInput 'host' '0' 'deck' '/home/deck' }
Assert-Throws { Test-ConnectionInput 'host' '22' 'deck@other' '/home/deck' }
Assert-Throws { Test-ConnectionInput 'host' '22' 'deck' 'relative' }
Assert-Throws { Get-ScannedKey @('not a key') }
Assert-Throws { Get-ScannedKey @('host ssh-ed25519 YQ==', 'host ssh-ed25519 Yg==') }
$key = Get-ScannedKey @('# ignored diagnostic', 'host ssh-ed25519 YQ==')
Assert-True ($key.Fingerprint -ceq 'SHA256:ypeBEsobvcr6wjGzmiPcTaeG7/gUfE5yuYB3ha/uSLs') 'Incorrect fingerprint.'

$mountArgs = @(Get-MountArguments '192.0.2.10' '02222' 'deck' '/My SD/$(bad);quote"' 'S:' 'C:\Users\Test User\key')
Assert-True ($mountArgs[0] -ceq 'deck@192.0.2.10:/My SD/$(bad);quote"') 'Remote path was changed.'
Assert-True ($mountArgs -contains 'StrictHostKeyChecking=yes') 'Host verification must be enabled.'
Assert-True ($mountArgs -contains 'HostKeyAlgorithms=ssh-ed25519') 'Must verify the displayed key type.'
Assert-True ($mountArgs -contains 'password_stdin') 'Password must go over stdin.'
Assert-True ($mountArgs -contains 'ssh_command=ssh.exe -F /dev/null') 'Must use the bundled SSH client on the child PATH.'
Assert-True ($mountArgs -contains 'UserKnownHostsFile="C:/Users/Test User/key"') 'Public key path must be quoted.'

# Ask a real child process what it received, including quotes, trailing slashes,
# empty strings, spaces and shell syntax. Nothing is evaluated by a shell.
$values = @('', 'space value', 'quote"value', 'C:\space dir\', '\\"', '$(NEVER_RUN);&') + $mountArgs
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

# Exercise the actual hidden-process setup with output larger than pipe buffers.
# This catches missing console handles and blocked/omitted failure diagnostics.
$start = New-SshfsStartInfo $Python @('-c', 'import sys; assert sys.stdin.readline() == "synthetic\n"; sys.stdout.write("o" * 131072); sys.stderr.write("Mount diagnostic\n" * 8192); sys.exit(37)')
$child = [Diagnostics.Process]::Start($start)
try {
    $output = $child.StandardOutput.ReadToEndAsync()
    $errors = $child.StandardError.ReadToEndAsync()
    $child.StandardInput.WriteLine('synthetic')
    $child.StandardInput.Close()
    Assert-True ($child.WaitForExit(10000)) 'Hidden child blocked while writing diagnostics.'
    Assert-True ($child.ExitCode -eq 37) 'Hidden child exit code was lost.'
    Assert-True ($output.Result.Length -eq 131072) 'Standard output was lost.'
    Assert-True ($errors.Result.StartsWith('Mount diagnostic')) 'Failure diagnostic was lost.'
} finally {
    if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
    $child.Dispose()
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
