$d="C:\dsio-idd"; New-Item $d -ItemType Directory -Force | Out-Null
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
Invoke-WebRequest "https://www.amyuni.com/downloads/usbmmidd_v2.zip" -OutFile "$d\u.zip" -UseBasicParsing
Expand-Archive "$d\u.zip" $d -Force
Set-Location "$d\usbmmidd_v2"
.\deviceinstaller64.exe install usbmmidd.inf usbmmidd
Start-Sleep 2
.\deviceinstaller64.exe enableidd 1
schtasks /create /tn "DSIO Virtual Display" /tr "\"$d\usbmmidd_v2\deviceinstaller64.exe\" enableidd 1" /sc onstart /ru SYSTEM /rl highest /f
$dst="$env:TEMP\DsioRemoteAgentSetup.exe"
Invoke-WebRequest "https://github.com/jiujitsumagician/dsio-remote-downloads/releases/download/v2.1.0/DsioRemoteAgentSetup.exe" -OutFile $dst -UseBasicParsing
Start-Process $dst -ArgumentList '/update'
