' Использование: cscript //nologo log_shipper.vbs "[Путь_к_логу]" "[URL_Webhook_n8n]" [Размер_Батча] [Таймаут_МС]
' Пример: cscript //nologo log_shipper.vbs "C:\nginx\logs\access.log" "http://localhost:5678/webhook-test/log-ingest" 50 2000

Dim objFSO, objLogFile, objPtrFile
Dim strLogPath, strWebhookUrl, intBatchSize, intSleepTime
Dim intLastLine, intCurrentLine, strLine, strBatchJson, intLinesInBatch

WScript.Echo "=================================================="
WScript.Echo "       ЗАПУСК ИНКРЕМЕНТАЛЬНОГО ЛОГ-ШИППЕРА        "
WScript.Echo "=================================================="

If WScript.Arguments.Count < 4 Then
    WScript.Echo "ОШИБКА: Недостаточно аргументов!"
    WScript.Echo "Синтаксис: cscript //nologo log_shipper.vbs [ПутьКЛогу] [WebhookURL] [РазмерБатча] [ПаузаМС]"
    WScript.Quit
End If

strLogPath = WScript.Arguments(0)
strWebhookUrl = WScript.Arguments(1)
intBatchSize = CInt(WScript.Arguments(2))
intSleepTime = CInt(WScript.Arguments(3))

WScript.Echo "[ИНФО] Целевой файл: " & strLogPath
WScript.Echo "[ИНФО] URL вебхука n8n: " & strWebhookUrl
WScript.Echo "[ИНФО] Размер порции (батч): " & intBatchSize & " строк"
WScript.Echo "[ИНФО] Задержка между порциями: " & intSleepTime & " мс"

Set objFSO = CreateObject("Scripting.FileSystemObject")

If Not objFSO.FileExists(strLogPath) Then
    WScript.Echo "КРИТИЧЕСКАЯ ОШИБКА: Файл лога не найден по указанному пути!"
    WScript.Quit
End If

' Проверка файла состояния (.ptr)
Dim strPtrPath
strPtrPath = strLogPath & ".ptr"

intLastLine = 0
If objFSO.FileExists(strPtrPath) Then
    Set objPtrFile = objFSO.OpenTextFile(strPtrPath, 1)
    If Not objPtrFile.AtEndOfStream Then
        Dim ptrValue
        ptrValue = objPtrFile.ReadLine
        If IsNumeric(ptrValue) Then intLastLine = CLng(ptrValue)
    End If
    objPtrFile.Close
    WScript.Echo "[ЧЕКПОИНТ] Найден .ptr файл. Начинаем со строки: " & intLastLine
Else
    WScript.Echo "[ЧЕКПОИНТ] Файл состояния не найден. Читаем лог с самого начала (строка 0)."
End If

Set objLogFile = objFSO.OpenTextFile(strLogPath, 1)
intCurrentLine = 0

' Пропуск старых строк
If intLastLine > 0 Then
    WScript.Echo "[ПРОЦЕСС] Пропускаю уже отправленные строки..."
    Do While intCurrentLine < intLastLine And Not objLogFile.AtEndOfStream
        objLogFile.SkipLine
        intCurrentLine = intCurrentLine + 1
    Loop
    WScript.Echo "[ПРОЦЕСС] Пропущено строк: " & intCurrentLine
End If

If objLogFile.AtEndOfStream Then
    WScript.Echo "[ЗАВЕРШЕНО] Новых строк в файле лога не обнаружено. Выхожу."
    objLogFile.Close
    WScript.Quit
End If

strBatchJson = "["
intLinesInBatch = 0
WScript.Echo "[ПРОЦЕСС] Чтение новых строк и формирование порций..."

Do While Not objLogFile.AtEndOfStream
    strLine = objLogFile.ReadLine
    intCurrentLine = intCurrentLine + 1
    
    ' Экранирование JSON
    strLine = Replace(strLine, "\", "\\")
    strLine = Replace(strLine, """", "\""")
    strLine = Replace(strLine, vbCr, "")
    strLine = Replace(strLine, vbLf, "")
    
    If intLinesInBatch > 0 Then
        strBatchJson = strBatchJson & ","
    End If
    
    strBatchJson = strBatchJson & "{""message"":""" & strLine & """}"
    intLinesInBatch = intLinesInBatch + 1
    
    ' Отправка заполненного батча
    If intLinesInBatch >= intBatchSize Then
        strBatchJson = strBatchJson & "]"
        WScript.Echo "[СЕТЬ] Накоплен батч из " & intLinesInBatch & " строк. Отправка..."
        
        SendBatch strWebhookUrl, strBatchJson
        
        WScript.Echo "[ПАУЗА] Засыпаю на " & intSleepTime & " мс..."
        WScript.Sleep intSleepTime
        
        strBatchJson = "["
        intLinesInBatch = 0
        SaveState strPtrPath, intCurrentLine
    End If
Loop

' Отправка остатка
If intLinesInBatch > 0 Then
    strBatchJson = strBatchJson & "]"
    WScript.Echo "[СЕТЬ] Отправка финального остатка логов (" & intLinesInBatch & " строк)..."
    SendBatch strWebhookUrl, strBatchJson
    SaveState strPtrPath, intCurrentLine
End If

objLogFile.Close
WScript.Echo "=================================================="
WScript.Echo "[УСПЕХ] Скрипт успешно завершил работу. Чекпоинт: " & intCurrentLine
WScript.Echo "=================================================="

' Функция отправки HTTP POST запроса
Sub SendBatch(url, json)
    Dim xmlHttp
    On Error Resume Next
    Set xmlHttp = CreateObject("MSXML2.ServerXMLHTTP.6.0") ' Использование более стабильной версии библиотеки
    
    xmlHttp.Open "POST", url, False
    xmlHttp.setRequestHeader "Content-Type", "application/json; charset=utf-8"
    
    xmlHttp.Send json
    
    If Err.Number <> 0 Then
        WScript.Echo "[ОШИБКА СЕТИ] Не удалось отправить данные! Описание: " & Err.Description & " (Код: " & Err.Number & ")"
        WScript.Echo "[СОВЕТ] Проверьте: запущен ли n8n, правильный ли порт и не блокирует ли брандмауэр."
        Err.Clear
    Else
        WScript.Echo "[ОТВЕТ n8n] HTTP Статус: " & xmlHttp.Status & " " & xmlHttp.statusText
        If xmlHttp.Status = 404 Then
            WScript.Echo "[ВНИМАНИЕ] Код 404 означает, что Вебхук в n8n не активирован или URL указан неверно!"
        Else
            WScript.Echo "[ОТВЕТ n8n] Текст ответа: " & xmlHttp.responseText
        End If
    End If
    On Error GoTo 0
End Sub

' Функция сохранения состояния
Sub SaveState(path, lineNum)
    Dim file
    On Error Resume Next
    Set file = objFSO.CreateTextFile(path, True)
    If Err.Number <> 0 Then
        WScript.Echo "[ОШИБКА СИСТЕМЫ] Не удалось записать файл чекпоинта " & path
        Err.Clear
    Else
        file.WriteLine lineNum
        file.Close
        WScript.Echo "[СИСТЕМА] Чекпоинт сохранен на строке: " & lineNum
    End If
    On Error GoTo 0
End Sub
