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
Write-Host 'Windows mount checks passed.'
