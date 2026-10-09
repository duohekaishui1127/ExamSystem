param([string]$SourceFile = '', [switch]$BenchmarkOnly, [int]$Count = 1500)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $SourceFile) { $SourceFile = Join-Path $root 'server.ps1' }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('exam-import-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp | Out-Null
try {
    $source = [IO.File]::ReadAllText($SourceFile)
    $source = $source.Substring(0, $source.IndexOf('$listener = New-Object'))
    $copy = Join-Path $temp 'server.ps1'
    [IO.File]::WriteAllText($copy, $source, (New-Object Text.UTF8Encoding($true)))
    . $copy
    function Assert($condition,$message) { if (-not $condition) { throw $message } }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $template = [IO.File]::ReadAllBytes((Join-Path $root 'QUESTION_IMPORT_TEMPLATE.xlsx'))
    if (-not $BenchmarkOnly) {
        $records = @(Read-XlsxImportRecords $template)
        Assert ($records.Count -eq 0) 'Untouched template must not import reference examples'
        # Populate the input sheet, retaining all reference examples elsewhere in the workbook.
        $filled = Join-Path $temp 'filled.xlsx'
        [IO.File]::WriteAllBytes($filled,$template)
        $zip=[IO.Compression.ZipFile]::Open($filled,[IO.Compression.ZipArchiveMode]::Update)
        try {
            $reader=New-Object IO.StreamReader($zip.GetEntry('xl/worksheets/sheet4.xml').Open())
            try { $inputXml=$reader.ReadToEnd() } finally { $reader.Dispose() }
            $zip.GetEntry('xl/worksheets/sheet1.xml').Delete()
            $writer=New-Object IO.StreamWriter($zip.CreateEntry('xl/worksheets/sheet1.xml').Open())
            try { $writer.Write($inputXml) } finally { $writer.Dispose() }
            # Reordering sheets must not cause reference examples to be imported.
            $reader=New-Object IO.StreamReader($zip.GetEntry('xl/workbook.xml').Open())
            try { [xml]$workbook=$reader.ReadToEnd() } finally { $reader.Dispose() }
            $sheets=$workbook.SelectSingleNode("//*[local-name()='sheets']")
            $reference=$sheets.SelectSingleNode("*[local-name()='sheet'][@name='示例参考']")
            [void]$sheets.PrependChild($reference)
            $zip.GetEntry('xl/workbook.xml').Delete()
            $writer=New-Object IO.StreamWriter($zip.CreateEntry('xl/workbook.xml').Open())
            try { $writer.Write($workbook.OuterXml) } finally { $writer.Dispose() }
        } finally { $zip.Dispose() }
        $records=@(Read-XlsxImportRecords ([IO.File]::ReadAllBytes($filled)))
        Assert ($records.Count -eq 5) 'Only input-sheet rows must be imported'

        $result = Import-QuestionRecords $records (Current-Exam)
        Assert ($result.importedCount -eq 5 -and $result.errors.Count -eq 0) 'XLSX import with choices'
        Assert ((Current-Exam).questions[3].type -eq 'single') 'Single type'
        Assert ((Current-Exam).questions[4].answerText -eq 'A,C') 'Multiple answer'
        Assert ((Current-Exam).questions[4].options.Count -eq 4) 'Four options'
        $csv = @(Read-CsvImportRecords ([IO.File]::ReadAllBytes((Join-Path $root 'QUESTION_IMPORT_TEMPLATE.csv'))))
        Assert ($csv.Count -eq 0) 'CSV template must contain headers only'
        $csvContent = ($records | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
        $csv = @(Read-CsvImportRecords ([Text.Encoding]::UTF8.GetBytes($csvContent)))
        Assert ($csv.Count -eq 5) 'Filled CSV rows'

        $result = Import-QuestionRecords $csv (Current-Exam)
        Assert ($result.importedCount -eq 5 -and $result.errors.Count -eq 0) 'CSV import with choices'
        $bad = @(
            [pscustomobject]@{'题型'='随便判断';'题目正文'='invalid';'判断结果'='正确'},
            [pscustomobject]@{'题型'='判断题';'题目正文'='invalid';'判断结果'='可能'},
            [pscustomobject]@{'题型'='选择题';'题目正文'='invalid';'作答方式'='随便'},
            [pscustomobject]@{'题型'='选择题';'题目正文'='invalid';'作答方式'='单选';'选项A'='a';'选项B'='b';'选项C'='c';'选项D'='d';'正确选项'='A,C'},
            [pscustomobject]@{'题型'='选择题';'题目正文'='invalid';'作答方式'='多选';'选项A'='a';'选项B'='b';'选项C'='c';'选项D'='d';'正确选项'='A'},
            [pscustomobject]@{'题型'='主观题';'题目正文'='valid';'标准答案'='text';'__sourceRow'=42}
        )
        $result = Import-QuestionRecords $bad (Current-Exam)
        Assert ($result.importedCount -eq 1 -and $result.errors.Count -eq 5) 'Invalid dropdown values must be rejected'
        $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $root 'QUESTION_IMPORT_TEMPLATE.xlsx'))
        try {
            $reader = New-Object IO.StreamReader($zip.GetEntry('xl/worksheets/sheet1.xml').Open())
            try { [xml]$sheet=$reader.ReadToEnd() } finally { $reader.Dispose() }
            $rules=$sheet.SelectNodes("//*[local-name()='dataValidation']")
            Assert ($rules.Count -eq 4) 'Four dropdown validations'
            foreach($rule in $rules) { Assert ($rule.errorStyle -eq 'stop' -and $rule.showErrorMessage -eq '1') 'Blocking validation' }
            Assert ($sheet.SelectNodes("//*[local-name()='row']").Count -eq 1) 'Input sheet contains only the header row'
        } finally { $zip.Dispose() }
        # Shared/rich strings and gaps in worksheet row numbers are common in files saved by Excel.
        $sparseFile = Join-Path $temp 'sparse.xlsx'
        [IO.File]::WriteAllBytes($sparseFile, $template)
        [xml]$sparseXml = New-WorksheetXml @(@('题型','题目正文','判断结果','错误部分','标准答案'),@('主观题','plain','','','answer'),@('主观题','missing answer','','',''))
        $ns = $sparseXml.DocumentElement.NamespaceURI
        $textCell = $sparseXml.SelectSingleNode("//*[local-name()='c' and @r='B2']")
        $textCell.RemoveAll(); $textCell.SetAttribute('r','B2'); $textCell.SetAttribute('t','s')
        $v = $sparseXml.CreateElement('v',$ns); $v.InnerText='0'; [void]$textCell.AppendChild($v)
        $lastRow = $sparseXml.SelectSingleNode("//*[local-name()='row' and @r='3']")
        $lastRow.SetAttribute('r','17')
        foreach ($cell in $lastRow.ChildNodes) { $cell.SetAttribute('r', $cell.GetAttribute('r').TrimEnd([char[]]'0123456789') + '17') }
        $blank = $sparseXml.CreateElement('row',$ns); $blank.SetAttribute('r','5')
        [void]$lastRow.ParentNode.InsertBefore($blank,$lastRow)
        $zip=[IO.Compression.ZipFile]::Open($sparseFile,[IO.Compression.ZipArchiveMode]::Update)
        try {
            $zip.GetEntry('xl/worksheets/sheet1.xml').Delete()
            $parts = @{'xl/worksheets/sheet1.xml'=$sparseXml.OuterXml; 'xl/sharedStrings.xml'="<sst xmlns='$ns'><si><r><t>rich</t></r><r><t xml:space='preserve'> text</t></r></si></sst>"}
            foreach ($name in $parts.Keys) {
                $writer=New-Object IO.StreamWriter($zip.CreateEntry($name).Open())
                try { $writer.Write($parts[$name]) } finally { $writer.Dispose() }
            }
        } finally { $zip.Dispose() }
        $sparseRecords=@(Read-XlsxImportRecords ([IO.File]::ReadAllBytes($sparseFile)))
        Assert ($sparseRecords.Count -eq 2 -and $sparseRecords[0].'题目正文' -eq 'rich text') 'Shared rich strings and blank rows'
        $result=Import-QuestionRecords $sparseRecords (Current-Exam)
        Assert ($result.importedCount -eq 1 -and $result.errors[0].StartsWith('第 17 行')) 'Original XLSX error row number'
        # CSV quoted commas and newlines remain supported.
        $quoted="题型,题目正文,标准答案`r`n主观题,`"line1`nline2, comma`",answer"
        $parsed=@(Read-CsvImportRecords ([Text.Encoding]::UTF8.GetBytes($quoted)))
        Assert ($parsed.Count -eq 1 -and $parsed[0].'题目正文'.Contains("`n")) 'Quoted multiline CSV'
    }
    $script:Data = New-DefaultData
    $rows = New-Object System.Collections.ArrayList
    [void]$rows.Add(@('题型','题目正文','判断结果','错误部分','标准答案'))
    for ($i=1;$i -le $Count;$i++) { [void]$rows.Add(@('主观题',"Question $i",'','',"Answer $i")) }
    $fixture=Join-Path $temp 'benchmark.xlsx'
    [IO.File]::WriteAllBytes($fixture,$template)
    $zip=[IO.Compression.ZipFile]::Open($fixture,[IO.Compression.ZipArchiveMode]::Update)
    try {
        $zip.GetEntry('xl/worksheets/sheet1.xml').Delete()
        $writer=New-Object IO.StreamWriter($zip.CreateEntry('xl/worksheets/sheet1.xml').Open())
        try { $writer.Write((New-WorksheetXml $rows.ToArray())) } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $parsed=@(Read-XlsxImportRecords ([IO.File]::ReadAllBytes($fixture)))
    $parseMs=$timer.ElapsedMilliseconds
    $timer.Restart()
    $result=Import-QuestionRecords $parsed (Current-Exam)
    $importMs=$timer.ElapsedMilliseconds
    Assert ($result.importedCount -eq $Count) 'Bulk row count'
    Assert ((Current-Exam).questions[-1].position -eq $Count) 'Bulk positions'
    $persisted=[IO.File]::ReadAllText($DataFile) | ConvertFrom-Json
    Assert ($persisted.currentExam.questions.Count -eq $Count) 'Persisted bulk count'
    Write-Output "PASS: rows=$Count XLSX_parse_ms=$parseMs import_and_save_ms=$importMs total_ms=$($parseMs+$importMs)"
    $csvText = ($parsed | Select-Object '题型','题目正文','判断结果','错误部分','标准答案' | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
    $script:Data = New-DefaultData
    $timer.Restart()
    $csvRecords = @(Read-CsvImportRecords ([Text.Encoding]::UTF8.GetBytes($csvText)))
    $csvParseMs = $timer.ElapsedMilliseconds
    $timer.Restart()
    $csvResult = Import-QuestionRecords $csvRecords (Current-Exam)
    $csvImportMs = $timer.ElapsedMilliseconds
    Assert ($csvResult.importedCount -eq $Count) 'Bulk CSV row count'
    Write-Output "PASS: rows=$Count CSV_parse_ms=$csvParseMs import_and_save_ms=$csvImportMs total_ms=$($csvParseMs+$csvImportMs)"
} finally { Remove-Item -Recurse -Force $temp }
