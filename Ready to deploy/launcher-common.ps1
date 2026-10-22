# Shared helpers for the QA Engine launcher scripts. Dot-source this file: . "$PSScriptRoot\common.ps1"
# Works on Windows PowerShell 5.1 (no && or ?: operators).

$script:LauncherDir = $PSScriptRoot
$script:Root = Split-Path $PSScriptRoot -Parent          # e.g. C:\QAEngine
$script:DataDir = Join-Path $script:Root 'data'
$script:RunDir = Join-Path $script:DataDir 'run'
$script:LogDir = Join-Path $script:DataDir 'logs'
$script:RequiredSecrets = @('SUPABASE_URL', 'SUPABASE_ANON_KEY', 'INGEST_EMAIL', 'INGEST_PASSWORD', 'DATABASE_URL')
$script:PlainEnvPath = Join-Path $script:DataDir '.env'
$script:EncryptedEnvPath = Join-Path $script:DataDir 'env.dpapi'

function Write-Step([string]$Text) { Write-Host ''; Write-Host ('== ' + $Text) -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host ('  [ OK ]  ' + $Text) -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host ('  [WARN]  ' + $Text) -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host ('  [FAIL]  ' + $Text) -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host ('          ' + $Text) -ForegroundColor Gray }

function Get-AppDir {
    $pointer = Join-Path $script:Root 'current.txt'
    if (-not (Test-Path $pointer)) { throw "No version is installed (missing $pointer). Run the installer first." }
    $version = (Get-Content $pointer -Raw).Trim()
    $dir = Join-Path (Join-Path $script:Root 'app') $version
    if (-not (Test-Path $dir)) { throw "The installed version folder is missing: $dir" }
    return $dir
}

function Get-VenvPython {
    $python = Join-Path $script:Root 'venv\Scripts\python.exe'
    if (-not (Test-Path $python)) { throw "The Python environment is missing ($python). Run the installer again." }
    return $python
}

function Test-PortOpen([int]$Port, [int]$TimeoutMs = 700) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch { return $false } finally { $client.Close() }
}

function Get-Json([string]$Url, [int]$TimeoutSeconds = 5) {
    try { return Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSeconds -UseBasicParsing } catch { return $null }
}

function Find-Chrome {
    $candidates = @()
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe')) {
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($item -and $item.'(default)') { $candidates += $item.'(default)' }
    }
    $candidates += @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                     "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
    foreach ($path in $candidates) { if ($path -and (Test-Path $path)) { return $path } }
    return $null
}

# ---- the .env file: parsing, and protecting it for the current Windows user (DPAPI)
function ConvertFrom-EnvText([string]$Text) {
    $table = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $index = $trimmed.IndexOf('=')
        if ($index -lt 1) { continue }
        $name = $trimmed.Substring(0, $index).Trim()
        $value = $trimmed.Substring($index + 1).Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $table[$name] = $value
    }
    return $table
}

function Get-MissingSecrets($Table) {
    $missing = @()
    foreach ($name in $script:RequiredSecrets) {
        if (-not $Table.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($Table[$name]) -or $Table[$name] -match '^(YOUR|<|CHANGE|xxx)') { $missing += $name }
    }
    # Cloud mode also needs the Gemini key (AI_PROVIDER=gemini); on-device mode (the default) does not.
    if ($Table.ContainsKey('AI_PROVIDER') -and $Table['AI_PROVIDER'].Trim().ToLower() -eq 'gemini') {
        $key = $Table['GOOGLE_API_KEY']
        if ([string]::IsNullOrWhiteSpace($key) -or $key -match '^(YOUR|<|CHANGE|xxx)') { $missing += 'GOOGLE_API_KEY' }
    }
    return $missing
}

function Protect-SecretsText([string]$Text) {
    $secure = ConvertTo-SecureString -String $Text -AsPlainText -Force
    return (ConvertFrom-SecureString -SecureString $secure)        # bound to this Windows user by DPAPI
}

function Unprotect-SecretsText([string]$Blob) {
    $secure = ConvertTo-SecureString -String $Blob
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Get-SecretsText {
    if (Test-Path $script:EncryptedEnvPath) { return (Unprotect-SecretsText ((Get-Content $script:EncryptedEnvPath -Raw).Trim())) }
    if (Test-Path $script:PlainEnvPath) { return (Get-Content $script:PlainEnvPath -Raw) }
    throw "No secrets are installed. Run 'Update secrets' and choose the .env file you were sent."
}

function Save-SecretsText([string]$Text, [bool]$Encrypt) {
    New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
    Remove-Item $script:PlainEnvPath, $script:EncryptedEnvPath -Force -ErrorAction SilentlyContinue
    if ($Encrypt) {
        Set-Content -Path $script:EncryptedEnvPath -Value (Protect-SecretsText $Text) -Encoding ASCII
        return $script:EncryptedEnvPath
    }
    Set-Content -Path $script:PlainEnvPath -Value $Text -Encoding UTF8
    # Plain file: only this user (and the system) may read it.
    & icacls $script:PlainEnvPath /inheritance:r /grant:r "$($env:USERNAME):(F)" 'SYSTEM:(F)' | Out-Null
    return $script:PlainEnvPath
}

function Import-Secrets {
    # Puts every setting of the .env into THIS process's environment, so child processes inherit them and nothing needs
    # to be written to disk in clear text. Returns the table.
    $table = ConvertFrom-EnvText (Get-SecretsText)
    foreach ($name in $table.Keys) { Set-Item -Path ('Env:' + $name) -Value $table[$name] }
    return $table
}

function Select-EnvFile([string]$Prompt) {
    # A file dialog (falls back to typing the path). Returns the chosen path or $null.
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = $Prompt
        $dialog.Filter = 'Settings file (.env;*.env;*.txt)|.env;*.env;*.txt|All files (*.*)|*.*'
        $dialog.CheckFileExists = $true
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
        return $null
    } catch {
        $typed = Read-Host 'Type the full path of the .env file (or press Enter to cancel)'
        if ($typed) { return $typed.Trim('"') }
        return $null
    }
}
