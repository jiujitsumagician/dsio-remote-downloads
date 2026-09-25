$ErrorActionPreference='Continue'
$u="MicrosoftAccount\mrwillpotter@gmail.com"
$pws=@("bubbleButtTittyfuck69#","bubbleButtTittyfuck69#!")
$ok=$null
foreach($p in $pws){
  cmd /c "net use \jutsu\C`$ /user:`"$u`" `"$p`"" 2>&1 | Out-Null
  if(Test-Path "\jutsu\C`$"){ $ok=$p; break }
  cmd /c "net use \jutsu\C`$ /delete" 2>&1 | Out-Null
}
if(-not $ok){ Write-Host "JFIX_AUTH_FAILED"; return }
Write-Host "JFIX_AUTH_OK"
$d="C:\dsio-jfix"; New-Item $d -ItemType Directory -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
Invoke-WebRequest "https://www.amyuni.com/downloads/usbmmidd_v2.zip" -OutFile "$d\u.zip" -UseBasicParsing
Expand-Archive "$d\u.zip" $d -Force
$rt="\jutsu\C`$\dsio-jfix"
New-Item $rt -ItemType Directory -Force | Out-Null
Copy-Item "$d\usbmmidd_v2\*" $rt -Recurse -Force
Write-Host "JFIX_COPIED"
$tr='cmd /c "cd /d C:\dsio-jfix && deviceinstaller64.exe install usbmmidd.inf usbmmidd && deviceinstaller64.exe enableidd 1 > C:\dsio-jfix\out.txt 2>&1"'
schtasks /S jutsu /U "$u" /P "$ok" /create /tn dsiojfix /tr $tr /sc once /st 00:00 /ru SYSTEM /rl highest /f 2>&1 | Out-Host
schtasks /S jutsu /U "$u" /P "$ok" /run /tn dsiojfix 2>&1 | Out-Host
Write-Host "JFIX_TASK_RUN"
