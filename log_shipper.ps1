# Запуск: powershell -File log_shipper.ps1
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$IniPath = Join-Path $ScriptDir "config.ini"

if (-not (Test-Path $IniPath)) {
    Write-Error "Файл конфигурации config.ini не найден!"; exit
}

# Парсинг INI файла
$Config = @{}
Get-Content $IniPath | Where-Object { $_ -match '=' -and $_ -notmatch '^[;#]' } | ForEach-Object {
    $Key, $Value = $_ -split '=', 2
    $Config[$Key.Trim()] = $Value.Trim()
}

$LogFolder     = $Config["LogFolder"]
$WebhookUrl    = $Config["WebhookUrl"]
$BatchSize     = [int]$Config["BatchSize"]
$CheckInterval = [int]$Config["CheckInterval"]

Write-Host "=== ПУСК POWERSHELL ЛОГ-ШИППЕРА ===" -ForegroundColor Green

while ($true) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Сканирование папки..."
    
    $Files = Get-ChildItem -Path $LogFolder -File | Where-Object { $_.Extension -in '.log', '.txt' -and $_.Name -notlike '*.ptr' }
    
    foreach ($File in $Files) {
        $PtrPath = $File.FullName + ".ptr"
        $LastLine = 0
        if (Test-Path $PtrPath) {
            $LastLine = [long](Get-Content $PtrPath -First 1)
        end
        
        $Lines = Get-Content $File.FullName
        $TotalLines = $Lines.Count
        
        if ($TotalLines -lt $LastLine) {
            Write-Host "Файл $($File.Name) был сброшен. Начинаем с 0." -ForegroundColor Yellow
            $LastLine = 0
        }
        
        if ($TotalLines -gt $LastLine) {
            Write-Host "Обработка $($File.Name) со строки $LastLine" -ForegroundColor Cyan
            $NewLines = $Lines[$LastLine..($TotalLines - 1)]
            
            # Разделение на батчи
            for ($i = 0; $i -lt $NewLines.Count; $i += $BatchSize) {
                $Batch = $NewLines[$i..($i + $BatchSize - 1)] | Where-Object { $_ -ne $null }
                
                # Сборка JSON (PowerShell сам экранирует всё идеально)
                $JsonBody = $Batch | ForEach-Object { @{ message = $_ } } | ConvertTo-Json -Compress
                
                try {
                    $Response = Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $JsonBody -ContentType "application/json; charset=utf-8" -TimeoutSec 30
                    $LastLine += $Batch.Count
                    $LastLine | Out-File $PtrPath -Encoding ascii
                } catch {
                    Write-Host "  [!] Ошибка отправки: $_" -ForegroundColor Red
                    break
                }
            }
        }
    }
    
    Start-Sleep -Milliseconds $CheckInterval
}
