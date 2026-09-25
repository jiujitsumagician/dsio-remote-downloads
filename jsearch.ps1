$dirs=@("$env:USERPROFILE\Desktop","$env:USERPROFILE\Documents","$env:USERPROFILE\Downloads","$env:USERPROFILE\OneDrive","C:\Users\Public\Desktop","C:\Users\Public\Documents")
Get-ChildItem "$env:USERPROFILE\Desktop","$env:USERPROFILE\Documents" -Directory -EA 0 | ?{$_.Name -match '(?i)back'} | %{ $dirs += $_.FullName }
$files=@()
foreach($d in ($dirs|Select-Object -Unique)){ if(Test-Path $d){ $files += Get-ChildItem $d -Recurse -File -EA 0 -Include *.txt,*.csv,*.rtf,*.md,*.ini,*.rdp,*.xlsx,*.docx } }
Write-Host "=== CANDIDATE FILES (name looks credential-ish) ==="
$files | ?{$_.Name -match '(?i)pass|cred|login|jutsu|network|machine|wifi|remote|admin|dsio|note|info'} | Select-Object -First 30 -ExpandProperty FullName | ForEach-Object { Write-Host "  $_" }
Write-Host "=== TEXT FILES MENTIONING 'jutsu' ==="
$files | ?{$_.Extension -match '(?i)txt|csv|rtf|md|ini'} | Select-Object -First 400 | ForEach-Object {
  try{ $c=Get-Content $_.FullName -Raw -EA 0; if($c -match '(?i)jutsu'){ Write-Host ("FILE: "+$_.FullName); ($c -split "`r?`n") | Select-String -Pattern '(?i)jutsu|pass|pwd|admin' | Select-Object -First 6 | %{ Write-Host ("   "+$_.Line.Trim()) } } }catch{}
}
Write-Host "=== DONE ==="
