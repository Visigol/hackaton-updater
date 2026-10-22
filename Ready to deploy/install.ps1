# QA Engine installer. Double-click Install.cmd (it runs this script).
# - installs the engine code next to this file's zip into C:\QAEngine (or -InstallDir)
# - asks for the .env file you were sent (secrets are NOT inside the zip) and stores it encrypted for this Windows user
# - creates the Python environment, installs the requirements, creates shortcuts and runs a self-test
param(
    [string]$InstallDir = 'C:\QAEngine',
    [string]$EnvFile,
    [switch]$PlainFile,      # store the .env as a plain file instead of encrypting it
    [switch]$SkipDeps,       # test only: do not create the Python environment
    [string]$PythonPath,     # optional: full path of a Python 3.12+ interpreter, if the installer cannot find it
    [switch]$NoShortcuts
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Step([string]$t) { Write-Host ''; Write-Host ("== " + $t) -ForegroundColor Cyan }
function Ok([string]$t) { Write-Host ("  [ OK ]  " + $t) -ForegroundColor Green }
function Warn([string]$t) { Write-Host ("  [WARN]  " + $t) -ForegroundColor Yellow }
function Fail([string]$t) { Write-Host ("  [FAIL]  " + $t) -ForegroundColor Red }

try {
    Write-Host '=============================================' -ForegroundColor Cyan
    Write-Host '   QA Engine installer' -ForegroundColor Cyan
    Write-Host '=============================================' -ForegroundColor Cyan

    # ---- 1. the package
    Step '1/6  Finding the package'
    $zip = Get-ChildItem -Path $here -Filter 'QA-Engine-*.zip' | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $zip) { throw 'QA-Engine-<version>.zip was not found next to this installer.' }
    $shaFile = $zip.FullName + '.sha256'
    if (Test-Path $shaFile) {
        $expected = ((Get-Content $shaFile -Raw).Trim() -split '\s+')[0].ToLower()
        $actual = (Get-FileHash -Path $zip.FullName -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) { throw 'The package is damaged or was changed (checksum mismatch). Ask for a new copy.' }
        Ok 'Package checksum is correct'
    } else { Warn 'No .sha256 file next to the zip: the package was not verified.' }
    $version = ($zip.BaseName -replace '^QA-Engine-', '')
    Ok "Package $($zip.Name) (version $version)"

    # ---- 2. the settings file (secrets)
    Step '2/6  Settings file (.env)'
    . (Join-Path $here 'launcher-common.ps1')       # same helpers the launcher uses, shipped beside the installer
    $envText = $null
    $haveSecrets = (Test-Path (Join-Path $InstallDir 'data\env.dpapi')) -or (Test-Path (Join-Path $InstallDir 'data\.env'))
    if (-not $EnvFile -and $haveSecrets) {
        Ok 'Settings from the earlier installation are kept (use Update-secrets.cmd to change them)'
    } else {
        if (-not $EnvFile) {
            Write-Host '  The settings (.env) file is not inside the package. Choose the file you were sent.' -ForegroundColor White
            $EnvFile = Select-EnvFile 'Choose the .env file you were sent'
        }
        if (-not $EnvFile -or -not (Test-Path $EnvFile)) { throw 'No .env file was chosen. Ask the developer for it and run the installer again.' }
        $envText = Get-Content $EnvFile -Raw
        $missing = Get-MissingSecrets (ConvertFrom-EnvText $envText)
        if ($missing.Count -gt 0) { throw ('The .env file is incomplete. Missing: ' + ($missing -join ', ')) }
        Ok 'The .env file has every required setting'
    }

    # Which AI this engine will use (decides what the installer checks and what it tells you at the end).
    $provider = 'nano'
    $providerText = $envText
    if (-not $providerText -and (Test-Path (Join-Path $InstallDir 'data\env.dpapi'))) {
        $providerText = Unprotect-SecretsText ((Get-Content (Join-Path $InstallDir 'data\env.dpapi') -Raw).Trim())
    } elseif (-not $providerText -and (Test-Path (Join-Path $InstallDir 'data\.env'))) {
        $providerText = Get-Content (Join-Path $InstallDir 'data\.env') -Raw
    }
    if ($providerText) {
        $chosen = (ConvertFrom-EnvText $providerText)['AI_PROVIDER']
        if ($chosen) { $provider = $chosen.Trim().ToLower() }
    }
    Ok "AI mode: $provider"

    # ---- 3. Python 3.12+ and Chrome
    Step '3/6  Python and Chrome'
    $pythonExe = $null
    if (-not $SkipDeps) {
        $tried = @()
        $minimum = [version]'3.12'
        function Get-PythonInfo([string]$Exe, [string[]]$Prefix = @()) {
            # Runs the interpreter and reports its real path and version, or $null if it is missing or is only the Microsoft Store stub.
            try {
                $out = & $Exe @Prefix -c "import sys; print(sys.executable + '|' + '%d.%d.%d' % sys.version_info[:3])" 2>$null
                if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
                $parts = ("$out").Trim().Split('|')
                if ($parts.Count -ne 2) { return $null }
                return [pscustomobject]@{ Path = $parts[0]; Version = [version]$parts[1]; Label = (@($Exe) + $Prefix) -join ' ' }
            } catch { return $null }
        }
        function Find-Python {
            $candidates = @()
            if ($PythonPath) { $candidates += , @($PythonPath) }
            foreach ($command in @(@('python'), @('python3'), @('py', '-3'), @('py', '-3.13'), @('py', '-3.12'), @('py', '-3.14'))) { $candidates += , $command }
            # Installed but not on PATH: the registry, then the usual folders.
            foreach ($key in 'HKCU:\SOFTWARE\Python\PythonCore', 'HKLM:\SOFTWARE\Python\PythonCore', 'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore') {
                foreach ($versionKey in (Get-ChildItem $key -ErrorAction SilentlyContinue)) {
                    $pyHome = (Get-ItemProperty (Join-Path $versionKey.PSPath 'InstallPath') -ErrorAction SilentlyContinue).'(default)'
                    if ($pyHome) { $candidates += , @((Join-Path $pyHome 'python.exe')) }
                }
            }
            foreach ($pattern in "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe", "${env:ProgramFiles(x86)}\Python3*\python.exe", 'C:\Python3*\python.exe') {
                foreach ($file in (Get-ChildItem $pattern -ErrorAction SilentlyContinue)) { $candidates += , @($file.FullName) }
            }
            $best = $null
            foreach ($candidate in $candidates) {
                $info = Get-PythonInfo $candidate[0] @($candidate | Select-Object -Skip 1)
                if (-not $info) { continue }
                $script:tried += ("{0} = Python {1}" -f $info.Label, $info.Version)
                if ($info.Version -ge $minimum -and (-not $best -or $info.Version -gt $best.Version)) { $best = $info }
            }
            return $best
        }

        $python = Find-Python
        if (-not $python) {
            Warn 'Python 3.12 or newer was not found. Trying to install it with winget...'
            try { & winget install --id Python.Python.3.12 --exact --silent --accept-package-agreements --accept-source-agreements | Out-Null } catch { }
            $python = Find-Python
        }
        if (-not $python) {
            $seen = if ($tried.Count) { ' Found: ' + (($tried | Select-Object -Unique) -join '; ') + '.' } else { ' No Python was found at all.' }
            throw ('Python 3.12 or newer is required.' + $seen + ' Install it from python.org (tick "Add python.exe to PATH"), or run: Install.cmd -PythonPath "C:\path\to\python.exe"')
        }
        $pythonExe = $python.Path
        Ok ("Python {0} found: {1}" -f $python.Version, $pythonExe)
    }
    if ($provider -eq 'nano') {
        if (Find-Chrome) { Ok 'Google Chrome found' } else { Warn 'Google Chrome was not found. Install it before starting the engine.' }
    } else { Ok 'Cloud Gemini mode: Chrome is not needed' }

    # ---- 4. files
    Step "4/6  Installing the files into $InstallDir"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $stopScript = Join-Path $InstallDir 'launcher\stop.ps1'
    if (Test-Path $stopScript) { & $stopScript | Out-Null }               # an update: stop the old engine first
    $appDir = Join-Path $InstallDir "app\$version"
    if (Test-Path $appDir) { Remove-Item $appDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $appDir | Out-Null
    Expand-Archive -Path $zip.FullName -DestinationPath $appDir -Force
    $launcherSource = Join-Path $appDir 'launcher'
    $launcherTarget = Join-Path $InstallDir 'launcher'
    New-Item -ItemType Directory -Force -Path $launcherTarget | Out-Null
    Copy-Item -Path (Join-Path $launcherSource '*') -Destination $launcherTarget -Force
    Set-Content -Path (Join-Path $InstallDir 'current.txt') -Value $version -Encoding ASCII
    foreach ($folder in 'data', 'data\inbox', 'data\processed', 'data\failed', 'data\logs', 'data\run') {
        New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir $folder) | Out-Null
    }
    Ok 'Files copied'

    # ---- 5. secrets + Python environment
    Step '5/6  Storing the secrets and building the Python environment'
    . (Join-Path $launcherTarget 'common.ps1')
    if ($envText) {
        $stored = Save-SecretsText $envText (-not $PlainFile)
        Ok "Secrets stored in $stored"
    } else { Ok 'Secrets unchanged' }
    if (-not $SkipDeps) {
        $venv = Join-Path $InstallDir 'venv'
        if (-not (Test-Path (Join-Path $venv 'Scripts\python.exe'))) {
            & $pythonExe -m venv $venv
            if ($LASTEXITCODE -ne 0) { throw 'Could not create the Python environment.' }
        }
        $venvPython = Join-Path $venv 'Scripts\python.exe'
        Write-Host '  Installing the requirements (a few minutes the first time)...'
        & $venvPython -m pip install --disable-pip-version-check --quiet --upgrade pip
        & $venvPython -m pip install --disable-pip-version-check --quiet -r (Join-Path $appDir 'requirements.txt')
        if ($LASTEXITCODE -ne 0) { throw 'Installing the requirements failed. Check the internet connection and run the installer again.' }
        Ok 'Requirements installed'
    } else { Warn 'Python environment skipped (test mode)' }

    # ---- 6. shortcuts + self-test
    Step '6/6  Shortcuts and self-test'
    if (-not $NoShortcuts) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $shell = New-Object -ComObject WScript.Shell
        foreach ($entry in @(@('QA Engine - Start', 'Start.cmd'), @('QA Engine - Stop', 'Stop.cmd'), @('QA Engine - Status', 'Status.cmd'), @('QA Engine - Show logs', 'Show-Logs.cmd'))) {
            $link = $shell.CreateShortcut((Join-Path $desktop ($entry[0] + '.lnk')))
            $link.TargetPath = Join-Path $launcherTarget $entry[1]
            $link.WorkingDirectory = $launcherTarget
            $link.Save()
        }
        Ok 'Desktop shortcuts created: Start, Stop, Status, Show logs'
    }
    if (-not $SkipDeps) {
        $check = & (Get-VenvPython) -c "import fastapi, playwright, psycopg, watchdog, supabase, neuro_san; print('imports ok')" 2>&1
        if ($check -match 'imports ok') { Ok 'Self-test: all key packages load' } else { Warn ('Self-test problem: ' + $check) }
    }

    Write-Host ''
    Write-Host 'Installation finished.' -ForegroundColor Green
    Write-Host '  1. Delete the .env file you were sent (and empty the Recycle Bin).' -ForegroundColor White
    Write-Host '  2. Double-click "QA Engine - Start" on the desktop.' -ForegroundColor White
    if ($provider -eq 'nano') {
        Write-Host '  3. The first start downloads Gemini Nano inside Chrome: see Installation-and-Documentation.html (Installation guide, Part 4).' -ForegroundColor White
    } else {
        Write-Host '  3. Cloud Gemini is selected: no model download and no Chrome window are needed.' -ForegroundColor White
    }
    exit 0
} catch {
    Write-Host ''
    Fail $_.Exception.Message
    Write-Host 'The installation did not finish. Nothing else was changed.' -ForegroundColor Red
    exit 1
}
