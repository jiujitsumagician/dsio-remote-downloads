# Re-enable the virtual display on every boot so jutsu never goes black headless again.
$dev = Get-ChildItem "C:\dsio-idd" -Recurse -Filter deviceinstaller64.exe -EA 0 | Select-Object -First 1
if($dev){ schtasks /create /tn "DSIO Virtual Display" /tr ('"'+$dev.FullName+'" enableidd 1') /sc onstart /ru SYSTEM /rl highest /f | Out-Null }
# Never sleep / hibernate (idle) — belt-and-suspenders.
powercfg /change standby-timeout-ac 0; powercfg /change standby-timeout-dc 0
powercfg /change monitor-timeout-ac 0; powercfg /change monitor-timeout-dc 0
powercfg /change hibernate-timeout-ac 0; powercfg /change hibernate-timeout-dc 0
powercfg /hibernate off
# Keep-awake task if the v2.1.0 agent (with /keepawake) is installed.
$a="C:\ProgramData\DsioRemote\bin\DsioRemoteAgentSetup.exe"
if(Test-Path $a){
  $v=(Get-Item $a).VersionInfo.FileVersion
  if($v -like '2.1*'){ schtasks /create /tn "DSIO Remote Keep Awake" /tr ('"'+$a+'" /keepawake') /sc onstart /ru SYSTEM /rl highest /f | Out-Null; schtasks /run /tn "DSIO Remote Keep Awake" | Out-Null }
}
"PERSIST_DONE VD=$([bool](Get-ScheduledTask -TaskName 'DSIO Virtual Display' -EA 0)) KA=$([bool](Get-ScheduledTask -TaskName 'DSIO Remote Keep Awake' -EA 0)) agentver=$((Get-Item $a -EA 0).VersionInfo.FileVersion)"
Read-Host "done - press enter"
