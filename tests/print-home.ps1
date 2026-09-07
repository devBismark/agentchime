# Prints the home directory this process resolved.
#
# tests/lifecycle-contract.ps1 runs it first to prove its disposable HOME
# actually took effect, before letting install.ps1 write anything.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output ("HOME=" + $HOME)
exit 0
