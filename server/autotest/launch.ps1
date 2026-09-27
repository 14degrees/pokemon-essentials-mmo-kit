param(
  [Parameter(Mandatory = $true)] [string]$GameDir,
  [Parameter(Mandatory = $true)] [string]$Instance,
  [Parameter(Mandatory = $true)] [string]$Channel
)
# Launch one autopilot-controlled debug window, minimized, and print its process id.
# Called by the autotest orchestrator from WSL (lib/autotest/windows.rb).
$env:PEMK_INSTANCE  = $Instance
$env:PEMK_AUTOPILOT = $Channel
# The debug boot plus a server-save hydration can overflow the default Ruby VM stack
# (the same setting as PlayMMO-debug.bat).
$env:RUBY_THREAD_VM_STACK_SIZE = '16777216'
$p = Start-Process -FilePath (Join-Path $GameDir 'Game.exe') -ArgumentList 'debug' `
                   -WorkingDirectory $GameDir -WindowStyle Minimized -PassThru
$p.Id
