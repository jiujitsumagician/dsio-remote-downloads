$dst="$env:TEMP\DsioRemoteAgentSetup.exe"
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
Invoke-WebRequest "https://github.com/jiujitsumagician/dsio-remote-downloads/releases/download/v2.1.0/DsioRemoteAgentSetup.exe" -OutFile $dst -UseBasicParsing
Start-Process $dst -ArgumentList '/update'
