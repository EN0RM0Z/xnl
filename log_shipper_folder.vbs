[Settings]
; Путь к папке, где лежат ваши лог-файлы (без закрывающего слэша)
LogFolder=C:\inetpub\logs\LogFiles

; URL вебхука n8n (тестовый или продакшн)
WebhookUrl=http://localhost:5678/webhook-test/log-ingest

; Размер порции отправки строк за один раз
BatchSize=50

; Интервал проверки папки на наличие новых логов (в миллисекундах: 5000 = 5 секунд)
CheckInterval=5000

==========================

Запускать его нужно так же через командную строку: cscript //nologo log_shipper.vbs

Option Explicit

Dim objFSO, objShell, strScriptFolder, strIniPath
Dim dictConfig, strLogFolder, strWebhookUrl, intBatchSize, intCheckInterval

Set objFSO = CreateObject("Scripting.FileSystemObject")
Set objShell = CreateObject("WScript.Shell")

' 1. Определение рабочей папки скрипта
strScriptFolder = objFSO.GetParentFolderName(WScript.ScriptFullName)
strIniPath = objFSO.BuildPath(strScriptFolder, "config.ini")

WScript.Echo "=================================================="
WScript.Echo "    ЗАПУСК НЕПРЕРЫВНОГО ЛОГ-ШИППЕРА (РЕЖИМ СЛУЖБЫ) "
WScript.Echo "=================================================="

' Чтение конфигурации
If Not objFSO.FileExists(strIniPath) Then
    WScript.Echo "КРИТИЧЕСКАЯ ОШИБКА: Файл конфигурации не найден!"
    WScript.Echo "Создайте файл: " & strIniPath
    WScript.Quit
End If

Set dictConfig = LoadIni(strIniPath)

' Проверка и присвоение параметров
If Not dictConfig.Exists("LogFolder") Or Not dictConfig.Exists("WebhookUrl") Then
    WScript.Echo "КРИТИЧЕСКАЯ ОШИБКА: В config.ini отсутствуют обязательные параметры LogFolder или WebhookUrl!"
    WScript.Quit
End If

strLogFolder = dictConfig("LogFolder")
strWebhookUrl = dictConfig("WebhookUrl")
intBatchSize = CInt(dictConfig("BatchSize"))
intCheckInterval = CInt(dictConfig("CheckInterval"))

WScript.Echo "[КОНФИГ] Папка мониторинга : " & strLogFolder
WScript.Echo "[КОНФИГ] Целевой URL n8n   : " & strWebhookUrl
WScript.Echo "[КОНФИГ] Размер батча      : " & intBatchSize & " строк"
WScript.Echo "[КОНФИГ] Интервал опроса   : " & intCheckInterval & " мс"
WScript.Echo "[ИНФО] Для остановки скрипта нажмите [Ctrl + C]"
WScript.Echo "--------------------------------------------------"

If Not objFSO.FolderExists(strLogFolder) Then
    WScript.Echo "КРИТИЧЕСКАЯ ОШИБКА: Указанная папка с логами не существует!"
    WScript.Quit
End If

' 3. ГЛАВНЫЙ БЕСКОНЕЧНЫЙ ЦИКЛ МОНИТОРИНГА
Do While True
    WScript.Echo vbCrLf & "[ЦИКЛ] Сканирование папки логов: " & Time
    
    ProcessFolder strLogFolder
    
    ' Ожидание перед следующей итерацией
    WScript.Sleep intCheckInterval
Loop

' ==================================================
' МЕТОДЫ И ФУНКЦИИ СКРИПТА
' ==================================================

' Обход всех файлов в папке
Sub ProcessFolder(FolderMap)
    Dim objFolder, objFile, strExt
    Set objFolder = objFSO.GetFolder(FolderMap)
    
    For Each objFile In objFolder.Files
        strExt = LCase(objFSO.GetExtensionName(objFile.Name))
        
        ' Обрабатываем файлы с расширением .log или .txt (исключая файлы состояния .ptr)
        If (strExt = "log" Or strExt = "txt") And Right(LCase(objFile.Name), 4) <> ".ptr" Then
            ProcessSingleLogFile objFile.Path, objFile.Name
        End If
    Next
End Sub

' Обработка конкретного лог-файла на основе его чекпоинта
Sub ProcessSingleLogFile(FilePath, FileName)
    Dim strPtrPath, intLastLine, intCurrentLine, objLogFile, objPtrFile
    Dim strLine, strBatchJson, intLinesInBatch, ptrValue
    
    strPtrPath = FilePath & ".ptr"
    intLastLine = 0
    
    ' Чтение чекпоинта для этого конкретного файла
    If objFSO.FileExists(strPtrPath) Then
        Set objPtrFile = objFSO.OpenTextFile(strPtrPath, 1)
        If Not objPtrFile.AtEndOfStream Then
            ptrValue = objPtrFile.ReadLine
            If IsNumeric(ptrValue) Then intLastLine = CLng(ptrValue)
        End If
        objPtrFile.Close
    End If
    
    Set objLogFile = objFSO.OpenTextFile(FilePath, 1)
    intCurrentLine = 0
    
    ' Пропуск уже обработанных строк
    If intLastLine > 0 Then
        Do While intCurrentLine < intLastLine And Not objLogFile.AtEndOfStream
            objLogFile.SkipLine
            intCurrentLine = intCurrentLine + 1
        Loop
    End If
    
    ' Если файл был очищен/ротирован (текущих строк меньше, чем старый чекпоинт)
    If intCurrentLine < intLastLine And objLogFile.AtEndOfStream Then
        WScript.Echo "[ФАЙЛ] " & FileName & " был ротирован/очищен. Сброс чекпоинта на 0."
        objLogFile.Close
        Set objLogFile = objFSO.OpenTextFile(FilePath, 1)
        intCurrentLine = 0
    End If
    
    ' Проверка на наличие новых данных
    If objLogFile.AtEndOfStream Then
        ' Если новых строк нет — выходим тихо, чтобы не спамить в консоль
        objLogFile.Close
        Exit Sub
    End If
    
    WScript.Echo "[ФАЙЛ] Найдена активность в: " & FileName & " (продолжаем со строки " & intCurrentLine & ")"
    
    strBatchJson = "["
    intLinesInBatch = 0
    
    Do While Not objLogFile.AtEndOfStream
        strLine = objLogFile.ReadLine
        intCurrentLine = intCurrentLine + 1
        
        ' Экранирование спецсимволов для валидного JSON
        strLine = Replace(strLine, "\", "\\")
        strLine = Replace(strLine, """", "\""")
        strLine = Replace(strLine, Chr(9), "\t")
        strLine = Replace(strLine, Chr(8), "\b")
        strLine = Replace(strLine, Chr(12), "\f")
        strLine = Replace(strLine, vbCr, "")
        strLine = Replace(strLine, vbLf, "")
        
        ' Очистка прочих битых управляющих символов
        Dim i
        For i = 0 To 31
            If i <> 9 And i <> 8 And i <> 12 Then
                strLine = Replace(strLine, Chr(i), "")
            End If
        Next
        
        If intLinesInBatch > 0 Then strBatchJson = strBatchJson & ","
        strBatchJson = strBatchJson & "{""message"":""" & strLine & """}"
        intLinesInBatch = intLinesInBatch + 1
        
        ' Отправка при наполнении батча
        If intLinesInBatch >= intBatchSize Then
            strBatchJson = strBatchJson & "]"
            WScript.Echo "  -> Отправка батча из " & intLinesInBatch & " строк..."
            SendBatch strWebhookUrl, strBatchJson
            SaveState strPtrPath, intCurrentLine
            
            strBatchJson = "["
            intLinesInBatch = 0
        End If
    Loop
    
    ' Отправка остатка строк файла
    If intLinesInBatch > 0 Then
        strBatchJson = strBatchJson & "]"
        WScript.Echo "  -> Отправка остатка из " & intLinesInBatch & " строк..."
        SendBatch strWebhookUrl, strBatchJson
        SaveState strPtrPath, intCurrentLine
    End If
    
    objLogFile.Close
    WScript.Echo "[УСПЕХ] Файл " & FileName & " обработан до строки " & intCurrentLine
End Sub

' Функция отправки HTTP POST запроса в n8n
Sub SendBatch(Url, JsonData)
    Dim xmlHttp
    On Error Resume Next
    Set xmlHttp = CreateObject("MSXML2.ServerXMLHTTP.6.0")
    
    xmlHttp.Open "POST", Url, False
    xmlHttp.setRequestHeader "Content-Type", "application/json; charset=utf-8"
    xmlHttp.Send JsonData
    
    If Err.Number <> 0 Then
        WScript.Echo "  [!] ОШИБКА СЕТИ: " & Err.Description
        Err.Clear
    Else
        If xmlHttp.Status <> 200 And xmlHttp.Status <> 201 Then
            WScript.Echo "  [!] ОТВЕТ СЕРВЕРА ОШИБКА: " & xmlHttp.Status & " " & xmlHttp.statusText
            WScript.Echo "  Детали: " & xmlHttp.responseText
        End If
    End If
    On Error GoTo 0
End Sub

' Запись чекпоинта
Sub SaveState(PtrPath, LineNum)
    Dim objFile
    On Error Resume Next
    Set objFile = objFSO.CreateTextFile(PtrPath, True)
    If Err.Number = 0 Then
        objFile.WriteLine LineNum
        objFile.Close
    End If
    On Error GoTo 0
End Sub

' Функция парсинга простейших INI файлов в Dictionary
Function LoadIni(IniPath)
    Dim objFile, strLine, intPos, strKey, strVal
    Dim dict: Set dict = CreateObject("Scripting.Dictionary")
    
    Set objFile = objFSO.OpenTextFile(IniPath, 1)
    Do While Not objFile.AtEndOfStream
        strLine = Trim(objFile.ReadLine)
        
        ' Игнорируем комментарии и пустые строки
        If strLine <> "" And Left(strLine, 1) <> ";" And Left(strLine, 1) <> "#" And Left(strLine, 1) <> "[" Then
            intPos = InStr(strLine, "=")
            If intPos > 0 Then
                strKey = Trim(Left(strLine, intPos - 1))
                strVal = Trim(Mid(strLine, intPos + 1))
                
                If dict.Exists(strKey) Then
                    dict.Item(strKey) = strVal
                Else
                    dict.Add strKey, strVal
                End If
            End If
        End If
    Loop
    objFile.Close
    Set LoadIni = dict
End Function
    
