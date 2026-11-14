@echo off
REM Install-Python.bat - single-file installer. Just double-click and accept the Windows prompt.
setlocal
set "SELF=%~f0"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights - please accept the Windows prompt...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
    if errorlevel 1 (
        echo.
        echo Could not get administrator rights. Nothing was installed.
        pause
    )
    exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:SELF); $m='#=#PAY'+'LOAD#=#'; $i=$t.IndexOf($m); if($i -lt 0){throw 'Installer payload missing from this file.'}; $p=Join-Path $env:TEMP 'Install-Python-run.ps1'; [IO.File]::WriteAllText($p,$t.Substring($i+$m.Length),(New-Object Text.UTF8Encoding $true)); & $p; exit $LASTEXITCODE"
if errorlevel 1 (
    echo.
    echo Something went wrong. See the messages above.
    pause
)
exit /b
#=#PAYLOAD#=#
# Install-Python.ps1
# Removes any existing Python (and related files/PATH entries), then installs the latest
# stable Python for Windows, adds it to PATH, and verifies python + pip.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'   # much faster Invoke-WebRequest downloads

function Wait-AndExit([int]$Code = 0) {
    Write-Host ""
    Read-Host "Press Enter to close this window"
    exit $Code
}

# ---------- 1. Self-elevate (UAC prompt) ----------
try {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    Write-Host "ERROR while checking admin rights: $($_.Exception.Message)" -ForegroundColor Red
    Wait-AndExit 1
}

if (-not $isAdmin) {
    Write-Host "Requesting administrator rights (accept the Windows prompt)..."
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
    if (-not $scriptPath) {
        Write-Host "ERROR: cannot work out this script's own path. Use Install-Python.bat instead." -ForegroundColor Red
        Wait-AndExit 1
    }
    try {
        # -NoExit keeps the elevated window open so any error stays readable
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
            "-NoProfile", "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`""
        )
    } catch {
        Write-Host "Elevation was cancelled or failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Python was not installed." -ForegroundColor Red
        Wait-AndExit 1
    }
    exit
}

# Keep a log of everything below so problems can be inspected afterwards
$logFile = Join-Path $env:TEMP 'Install-Python.log'
try { Start-Transcript -Path $logFile -Force | Out-Null } catch { }
Write-Host "Running as administrator. Log file: $logFile" -ForegroundColor DarkGray

# ---------- 2. Remove any existing Python ----------
function Get-PythonUninstallEntries {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($item in Get-ChildItem $root -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty $item.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -and ($p.Publisher -eq 'Python Software Foundation' -or $p.DisplayName -match '^Python \d+\.\d+')) {
                [pscustomobject]@{
                    Name            = $p.DisplayName
                    Key             = $item.PSChildName
                    UninstallString = [string]$p.UninstallString
                }
            }
        }
    }
}

function Clear-PythonFromEnvironment($rootKey, $subKey, $label) {
    $key = $rootKey.OpenSubKey($subKey, $true)
    if (-not $key) { return }
    try {
        $raw = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($raw) {
            $keep = @()
            foreach ($entry in ($raw -split ';')) {
                if ($entry -eq '') { continue }
                $expanded = [Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\')
                if ($expanded -match '(?i)\\Python[\d\.\-]*(\\Scripts)?$' -or
                    $expanded -match '(?i)\\Programs\\Python(\\|$)' -or
                    $expanded -match '(?i)\\Python Launcher$' -or
                    $expanded -match '(?i)\\Python\\bin$') {
                    Write-Host "  Removing from $label PATH: $entry"
                } else {
                    $keep += $entry
                }
            }
            $key.SetValue('Path', ($keep -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
        }
        foreach ($var in 'PYTHONHOME', 'PYTHONPATH') {
            if ($null -ne $key.GetValue($var, $null)) {
                Write-Host "  Removing $label variable: $var"
                $key.DeleteValue($var, $false)
            }
        }
    } finally { $key.Close() }
}

function Remove-ExistingPython {
    Write-Host "Checking for an existing Python installation..." -ForegroundColor Cyan

    # 2a. Stop running Python processes so files are not locked
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(python|pythonw|pip|py|pyw)\d*$' } |
        ForEach-Object {
            Write-Host "  Stopping process $($_.Name) (PID $($_.Id))"
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }

    # 2b. Run the official uninstallers (bundles first, then any leftover MSI components)
    foreach ($pass in 1..2) {
        $entries = @(Get-PythonUninstallEntries | Sort-Object { $_.UninstallString -match 'msiexec' })
        if ($entries.Count -eq 0) { break }
        foreach ($e in $entries) {
            Write-Host "  Uninstalling: $($e.Name)"
            try {
                if ($e.UninstallString -match 'msiexec') {
                    if ($e.Key -match '^\{.+\}$') {
                        $null = Start-Process msiexec.exe -ArgumentList '/x', $e.Key, '/qn', '/norestart' -Wait -PassThru
                    }
                } elseif ($e.UninstallString -match '^\s*"?([^"]+?\.exe)"?') {
                    $exe = $Matches[1]
                    if (Test-Path $exe) {
                        $null = Start-Process $exe -ArgumentList '/uninstall', '/quiet' -Wait -PassThru
                    }
                }
            } catch {
                Write-Host "    Warning: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    # 2c. Microsoft Store version of Python
    try {
        Get-AppxPackage -AllUsers -Name 'PythonSoftwareFoundation.Python*' -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-Host "  Removing Store package: $($_.Name)"
                Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            }
    } catch { }

    # 2d. Delete leftover folders and files
    $dirs = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:SystemDrive\")) {
        if ($base -and (Test-Path $base)) {
            $dirs += Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^Python[\d\.\-]*( Launcher)?$' } |
                Select-Object -ExpandProperty FullName
        }
    }
    $dirs += @(
        "$env:LOCALAPPDATA\Programs\Python",
        "$env:LOCALAPPDATA\Python",
        "$env:LOCALAPPDATA\pip",
        "$env:APPDATA\Python",
        "$env:APPDATA\pip"
    )
    foreach ($d in ($dirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)) {
        Write-Host "  Deleting folder: $d"
        try { Remove-Item $d -Recurse -Force -ErrorAction Stop }
        catch { Write-Host "    Warning: could not fully delete ($($_.Exception.Message))" -ForegroundColor Yellow }
    }
    foreach ($f in 'py.exe', 'pyw.exe', 'py.ini') {
        $path = Join-Path $env:windir $f
        if (Test-Path $path) {
            Write-Host "  Deleting file: $path"
            Remove-Item $path -Force -ErrorAction SilentlyContinue
        }
    }

    # 2e. Registry leftovers
    foreach ($k in 'HKLM:\SOFTWARE\Python', 'HKLM:\SOFTWARE\WOW6432Node\Python', 'HKCU:\SOFTWARE\Python') {
        if (Test-Path $k) {
            Write-Host "  Deleting registry key: $k"
            Remove-Item $k -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # 2f. PATH entries and PYTHONHOME / PYTHONPATH
    Clear-PythonFromEnvironment ([Microsoft.Win32.Registry]::LocalMachine) 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' 'system'
    Clear-PythonFromEnvironment ([Microsoft.Win32.Registry]::CurrentUser) 'Environment' 'user'

    # Refresh PATH in this session so the old Python is no longer found
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

    Write-Host "Old Python cleanup finished." -ForegroundColor Green
    Write-Host ""
}

try {
    Remove-ExistingPython

    # ---------- 3. Find latest stable version that has a Windows installer ----------
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' }
            elseif ([Environment]::Is64BitOperatingSystem) { 'amd64' }
            else { 'win32' }

    Write-Host "Looking up the latest stable Python release ($arch)..." -ForegroundColor Cyan
    $baseUrl = "https://www.python.org/ftp/python"
    $listing = Invoke-WebRequest -Uri "$baseUrl/" -UseBasicParsing

    # Only plain X.Y.Z folders = stable releases (no alpha/beta/rc)
    $versions = [regex]::Matches($listing.Content, 'href="(\d+\.\d+\.\d+)/"') |
        ForEach-Object { [version]$_.Groups[1].Value } |
        Sort-Object -Descending -Unique

    $installerUrl = $null
    $chosen = $null
    foreach ($v in ($versions | Select-Object -First 25)) {
        $name = if ($arch -eq 'win32') { "python-$v.exe" } else { "python-$v-$arch.exe" }
        $url  = "$baseUrl/$v/$name"
        try {
            $null = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing
            $installerUrl = $url; $chosen = $v; $installerName = $name
            break
        } catch { continue }   # security-only releases have no installer
    }
    if (-not $installerUrl) { throw "Could not find a Windows installer on python.org." }
    Write-Host "Latest stable version: Python $chosen" -ForegroundColor Green

    # ---------- 3. Download ----------
    $installer = Join-Path $env:TEMP $installerName
    Write-Host "Downloading $installerUrl ..."
    Invoke-WebRequest -Uri $installerUrl -OutFile $installer -UseBasicParsing

    # ---------- 4. Install (all users, PATH, pip, py launcher) ----------
    Write-Host "Installing Python $chosen (this can take a minute)..." -ForegroundColor Cyan
    $installArgs = @("/quiet", "InstallAllUsers=1", "PrependPath=1", "Include_pip=1",
              "Include_launcher=1", "Include_test=0", "Include_doc=0")
    $proc = Start-Process -FilePath $installer -ArgumentList $installArgs -Wait -PassThru
    if ($proc.ExitCode -notin 0, 3010) { throw "Installer failed with exit code $($proc.ExitCode)." }
    Remove-Item $installer -Force -ErrorAction SilentlyContinue

    # ---------- 5. Refresh PATH in this session ----------
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path    = "$machinePath;$userPath"

    # Notify running apps (Explorer, new terminals) that environment variables changed
    Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    $r = [UIntPtr]::Zero
    [void][Win32.Native]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$r)

    # ---------- 6. Verify ----------
    Write-Host ""
    Write-Host "Verifying installation..." -ForegroundColor Cyan
    $ok = $true

    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pyCmd) {
        Write-Host "python found at: $($pyCmd.Source)"
        $out = & python --version 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host "  python --version      -> $out" -ForegroundColor Green }
        else { Write-Host "  python --version FAILED: $out" -ForegroundColor Red; $ok = $false }
    } else { Write-Host "  python not found on PATH" -ForegroundColor Red; $ok = $false }

    $out = & python -m pip --version 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Host "  python -m pip --version -> $out" -ForegroundColor Green }
    else { Write-Host "  python -m pip FAILED: $out" -ForegroundColor Red; $ok = $false }

    $pipCmd = Get-Command pip -ErrorAction SilentlyContinue
    if ($pipCmd) {
        $out = & pip --version 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host "  pip --version         -> $out" -ForegroundColor Green }
        else { Write-Host "  pip --version FAILED: $out" -ForegroundColor Red; $ok = $false }
    } else { Write-Host "  pip not found on PATH" -ForegroundColor Red; $ok = $false }

    Write-Host ""
    if ($ok) {
        Write-Host "Done! Python $chosen is installed and on PATH." -ForegroundColor Green
        Write-Host "Open a NEW terminal window to use python and pip anywhere."
        Wait-AndExit 0
    } else {
        Write-Host "Python installed, but some checks failed. Try opening a new terminal and running 'python --version' and 'pip --version'." -ForegroundColor Yellow
        Wait-AndExit 1
    }
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Wait-AndExit 1
}
