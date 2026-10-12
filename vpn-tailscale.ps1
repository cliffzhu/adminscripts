$installer = Join-Path $env:TEMP 'tailscale-setup-latest.exe'
Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe' -OutFile $installer -ErrorAction Stop
$process = Start-Process -FilePath $installer -ArgumentList '/install /quiet /norestart' -Wait -PassThru
"Installer exit code: $($process.ExitCode)"
& "$env:ProgramFiles\Tailscale\tailscale.exe" up --auth-key="tskey-auth-kiRRKuLEEx11CNTRL-4Gov2MUy9XPyrhJcdkDiXPEwGjmPkxqtW" --unattended
