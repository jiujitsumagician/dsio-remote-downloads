# DSIO Remote - install a software virtual display so a headless GPU has a render surface.
$ErrorActionPreference = 'Continue'
$raw   = 'https://raw.githubusercontent.com/jiujitsumagician/dsio-remote-downloads/master/j.ps1'
$topic = 'https://ntfy.sh/dsio-idd-514361c8d7d039fa'
function Beacon($m){ try{ Invoke-RestMethod -Uri $topic -Method Post -Body ([string]$m) -TimeoutSec 12 | Out-Null }catch{} }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
Beacon("start admin=$admin winver=$([Environment]::OSVersion.Version)")

if(-not $admin){
  Beacon("elevating")
  try{
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',"irm $raw | iex"
    Beacon("elevate-launched")
  }catch{ Beacon("elevate-fail $($_.Exception.Message)") }
  return
}

Beacon("admin-ok")
$dir = 'C:\ProgramData\dsio-idd'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$zip = Join-Path $dir 'usbmmidd_v2.zip'
try{
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri 'https://www.amyuni.com/downloads/usbmmidd_v2.zip' -OutFile $zip -UseBasicParsing
  Beacon("zip=$((Get-Item $zip).Length)")
}catch{ Beacon("dl-fail $($_.Exception.Message)"); return }

try{ Expand-Archive -Path $zip -DestinationPath $dir -Force }catch{ Beacon("unzip-fail $($_.Exception.Message)"); return }
$app = Join-Path $dir 'usbmmidd_v2'
$ex  = Join-Path $app 'deviceinstaller64.exe'
if(-not (Test-Path $ex)){ Beacon("no-exe"); return }

Set-Location $app
$r1 = (& $ex install usbmmidd.inf usbmmidd 2>&1 | Out-String)
Start-Sleep -Seconds 2
$r2 = (& $ex enableidd 1 2>&1 | Out-String)
Beacon("installed r1=$([regex]::Match($r1,'(?i)(signed|error|fail|success)').Value) r2=$($r2.Trim() -replace '\s+',' ')")

# Persist: re-activate the virtual monitor at every boot.
try{
  schtasks /Create /TN 'DSIO Remote Virtual Display' /TR "`"$ex`" enableidd 1" /SC ONSTART /RU SYSTEM /RL HIGHEST /F | Out-Null
  Beacon("task-created")
}catch{ Beacon("task-fail $($_.Exception.Message)") }

Start-Sleep -Seconds 2
$mons = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'USB Mobile Monitor|Idd' }).Count
Beacon("done virtual-monitor-devices=$mons")
