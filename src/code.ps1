# --- НАСТРОЙКИ ---

# Путь к папке, где лежат исходные файлы ( "." означает текущая папка)
$SourcePath = ".\" 

# Имя итогового файла
$OutputFileName = "all_code.txt"

# Какие файлы искать (например, "*.cs", "*.py" или "*.*" для всех)
$FileFilter = "*.*" 

# Исключить сам скрипт и итоговый файл, чтобы не было рекурсии
$ScriptFile = $MyInvocation.MyCommand.Source
$OutputFileFullPath = Join-Path (Resolve-Path $SourcePath) $OutputFileName

# --- СКРИПТ ---

# Если старый файл результата существует — удаляем его, чтобы создать новый
if (Test-Path $OutputFileFullPath) {
    Remove-Item $OutputFileFullPath
}

# Получаем список файлов рекурсивно
$Files = Get-ChildItem -Path $SourcePath -Recurse -Include $FileFilter -File | 
    Where-Object { 
        $_.FullName -ne $OutputFileFullPath -and 
        $_.FullName -ne $ScriptFile 
    }

Write-Host "Найдено файлов: $($Files.Count). Начинаю объединение..." -ForegroundColor Cyan

foreach ($File in $Files) {
    try {
        # Читаем содержимое файла
        $Content = Get-Content -Path $File.FullName -Raw -ErrorAction Stop
        
        # Формируем заголовок и блок (используем ''', как вы просили)
        $Header = "File: $($File.FullName)"
        $BlockStart = "'''" 
        $BlockEnd = "'''"
        $Separator = "`r`n" # Перенос строки

        # Собираем текст для записи
        $FinalText = $Header + $Separator + $BlockStart + $Separator + $Content + $Separator + $BlockEnd + $Separator + $Separator

        # Дописываем в итоговый файл (кодировка UTF8, чтобы русский текст не ломался)
        Add-Content -Path $OutputFileFullPath -Value $FinalText -Encoding UTF8
    }
    catch {
        Write-Warning "Не удалось прочитать файл: $($File.FullName)"
    }
}

Write-Host "Готово! Результат сохранен в: $OutputFileFullPath" -ForegroundColor Green