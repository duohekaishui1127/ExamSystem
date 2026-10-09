param(
    [int]$Port = 8080
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WebDir = Join-Path $BaseDir "web"
$DataDir = Join-Path $BaseDir "data"
$DataFile = Join-Path $DataDir "exam_data.json"
$HistoryDir = Join-Path $DataDir "history"
$MediaDir = Join-Path $DataDir "media"
if (-not (Test-Path $MediaDir)) { New-Item -ItemType Directory -Path $MediaDir | Out-Null }

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
if (-not (Test-Path $HistoryDir)) { New-Item -ItemType Directory -Path $HistoryDir | Out-Null }

function Date-ToString {
    param([datetime]$Date)
    return $Date.ToString("yyyy-MM-dd HH:mm:ss")
}

function String-ToDate {
    param([string]$Text)
    return [datetime]::ParseExact($Text, "yyyy-MM-dd HH:mm:ss", $null)
}

function New-ExamId {
    return "EXAM-" + (Get-Date).ToString("yyyyMMdd-HHmmss") + "-" + ([Guid]::NewGuid().ToString("N").Substring(0, 6))
}

function New-DraftExam {
    param(
        [string]$Name = "知识测验",
        [int]$DurationMinutes = 30,
        [double]$PassScore = 80,
        [string]$AccessCode = "123456",
        [bool]$RandomizeQuestions = $true,
        [string]$ScoringMode = "accuracy"
    )

    return [ordered]@{
        id = (New-ExamId)
        status = "draft"
        name = $Name
        durationMinutes = $DurationMinutes
        passScore = $PassScore
        scoringMode = $ScoringMode
        accessCode = $AccessCode
        randomizeQuestions = $RandomizeQuestions
        createdAt = (Date-ToString (Get-Date))
        startedAt = ""
        endedAt = ""
        questions = @()
        activeQuestions = @()
        participants = @()
    }
}

function New-DefaultData {
    return [ordered]@{
        version = 3
        admin = [ordered]@{
            user = "admin"
            password = "admin123"
        }
        counters = [ordered]@{
            question = 0
            participant = 0
        }
        currentExam = (New-DraftExam)
    }
}

function Save-JsonFile {
    param(
        [string]$Path,
        $Object
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $json = $Object | ConvertTo-Json -Depth 40
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Deep-Clone {
    param($Object)
    if ($null -eq $Object) { return $null }
    return (($Object | ConvertTo-Json -Depth 40) | ConvertFrom-Json)
}

function Convert-LegacyData {
    param($Legacy)

    $d = New-DefaultData

    if ($null -ne $Legacy.settings) {
        if ($Legacy.settings.adminUser) { $d.admin.user = [string]$Legacy.settings.adminUser }
        if ($Legacy.settings.adminPassword) { $d.admin.password = [string]$Legacy.settings.adminPassword }

        $legacyExamParams = @{
            Name = [string]$Legacy.settings.examName
            DurationMinutes = [int]$Legacy.settings.durationMinutes
            PassScore = [double]$Legacy.settings.passScore
            AccessCode = [string]$Legacy.settings.accessCode
            RandomizeQuestions = [bool]$Legacy.settings.randomizeQuestions
            ScoringMode = "score"
        }

        $exam = New-DraftExam @legacyExamParams

        $exam.questions = @($Legacy.questions)
        $exam.participants = @($Legacy.participants)

        if ([bool]$Legacy.settings.isActive) {
            $exam.status = "running"
            $exam.startedAt = Date-ToString (Get-Date)
            $exam.activeQuestions = @($Legacy.questions | Where-Object { $_.enabled -eq $true })
        }

        $d.currentExam = $exam
    }

    if ($null -ne $Legacy.counters) {
        $d.counters.question = [int]$Legacy.counters.question
        $d.counters.participant = [int]$Legacy.counters.participant
    }

    return $d
}

function Load-Data {
    if (-not (Test-Path $DataFile)) {
        $d = New-DefaultData
        Save-JsonFile $DataFile $d
        return $d
    }

    try {
        $raw = [System.IO.File]::ReadAllText($DataFile, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { throw "Empty data file" }
        $d = $raw | ConvertFrom-Json

        if ($null -eq $d.version -or [int]$d.version -lt 2) {
            $backup = Join-Path $DataDir ("exam_data_v1_backup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".json")
            Copy-Item $DataFile $backup -Force
            $d = Convert-LegacyData $d
            Save-JsonFile $DataFile $d
        }

        if ([int]$d.version -lt 3) {
            $backup = Join-Path $DataDir ("exam_data_v2_backup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".json")
            Copy-Item $DataFile $backup -Force
            if ($null -eq $d.currentExam.PSObject.Properties["scoringMode"]) {
                $d.currentExam | Add-Member -NotePropertyName scoringMode -NotePropertyValue "score"
            }
            $d.version = 3
            Save-JsonFile $DataFile $d
        }

        return $d
    }
    catch {
        $backup = Join-Path $DataDir ("exam_data_broken_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".json")
        Copy-Item $DataFile $backup -ErrorAction SilentlyContinue
        $d = New-DefaultData
        Save-JsonFile $DataFile $d
        return $d
    }
}

$script:Data = Load-Data
$script:AdminTokens = @{}

function Save-Data {
    Save-JsonFile $DataFile $script:Data
}

function As-Array {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-HeaderValue {
    param(
        [hashtable]$Headers,
        [string]$Name
    )
    foreach ($key in $Headers.Keys) {
        if ($key -ieq $Name) { return [string]$Headers[$key] }
    }
    return ""
}

function Parse-JsonBody {
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    try { return ($Body | ConvertFrom-Json) } catch { return $null }
}

function New-Token {
    return [Guid]::NewGuid().ToString("N")
}

function Normalize-Subjective {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $lower = $Text.ToLowerInvariant()
    return [regex]::Replace($lower, "[^\p{L}\p{Nd}]", "")
}


function Get-SafeCorrectionText {
    param($Question)

    if ($null -eq $Question) { return "" }
    if ([string]$Question.type -ne "correction") { return "" }
    if ([bool]$Question.noError) { return "" }
    if ($null -eq $Question.errorStart -or $null -eq $Question.errorEnd) { return "" }

    $text = [string]$Question.text
    $start = [int]$Question.errorStart
    $end = [int]$Question.errorEnd

    if ($start -lt 0) { $start = 0 }
    if ($start -gt $text.Length) { return "" }
    if ($end -lt $start) { return "" }
    if ($end -gt $text.Length) { $end = $text.Length }
    if ($end -le $start) { return "" }

    return $text.Substring($start, $end - $start)
}

function Get-SafeClickedCharacter {
    param(
        $Question,
        [int]$Index
    )

    if ($null -eq $Question) { return "" }

    $text = [string]$Question.text
    if ($Index -lt 0 -or $Index -ge $text.Length) {
        return ""
    }

    try {
        return $text.Substring($Index, 1)
    }
    catch {
        return ""
    }
}



function Get-AnswerReveal {
    param($Question)

    if ($null -eq $Question) { return $null }

    if ([string]$Question.type -in @("subjective","single","multiple")) {
        return [ordered]@{
            type = [string]$Question.type
            answerText = [string]$Question.answerText
        }
    }

    if ([bool]$Question.noError) {
        return [ordered]@{
            type = "correction"
            noError = $true
            text = [string]$Question.text
            errorStart = $null
            errorEnd = $null
            correctText = "本题正确"
        }
    }

    return [ordered]@{
        type = "correction"
        noError = $false
        text = [string]$Question.text
        errorStart = [int]$Question.errorStart
        errorEnd = [int]$Question.errorEnd
        correctText = (Get-SafeCorrectionText $Question)
    }
}


function Set-ObjectProperty {
    param(
        $Object,
        [string]$Name,
        $Value
    )

    if ($null -eq $Object) { return }

    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Save-HistoryExam {
    param($Exam)

    if ($null -eq $Exam -or [string]::IsNullOrWhiteSpace([string]$Exam.id)) { return }
    $path = Join-Path $HistoryDir (([string]$Exam.id) + ".json")
    Save-JsonFile $path $Exam
}

function Apply-AnswerReview {
    param(
        $Participant,
        [int]$QuestionId,
        [bool]$IsCorrect,
        [bool]$RestoreAuto = $false,
        [string]$Note = ""
    )

    if ($null -eq $Participant) { return $null }

    $answer = As-Array $Participant.answers |
        Where-Object { [int]$_.questionId -eq $QuestionId } |
        Select-Object -First 1

    if ($null -eq $answer) { return $null }

    if ($null -eq $answer.PSObject.Properties["autoIsCorrect"]) {
        Set-ObjectProperty $answer "autoIsCorrect" ([bool]$answer.isCorrect)
    }

    if ($RestoreAuto) {
        Set-ObjectProperty $answer "isCorrect" ([bool]$answer.autoIsCorrect)
        Set-ObjectProperty $answer "adminOverride" $false
        Set-ObjectProperty $answer "reviewedAt" ""
        Set-ObjectProperty $answer "reviewNote" ""
    }
    else {
        Set-ObjectProperty $answer "isCorrect" ([bool]$IsCorrect)
        Set-ObjectProperty $answer "adminOverride" $true
        Set-ObjectProperty $answer "reviewedAt" (Date-ToString (Get-Date))
        Set-ObjectProperty $answer "reviewNote" ([string]$Note)
    }

    Recalculate-Participant $Participant
    return $answer
}

function Test-ParticipantOnline {
    param($Participant)

    if ($null -eq $Participant) { return $false }

    $lastSeenText = ""
    if ($null -ne $Participant.PSObject.Properties["lastSeenAt"]) {
        $lastSeenText = [string]$Participant.lastSeenAt
    }

    if ([string]::IsNullOrWhiteSpace($lastSeenText)) { return $false }

    try {
        $lastSeen = String-ToDate $lastSeenText
        return (((Get-Date) - $lastSeen).TotalSeconds -le 20)
    }
    catch {
        return $false
    }
}

function Current-Exam {
    return $script:Data.currentExam
}

function Get-DraftQuestion {
    param([int]$Id)
    return (As-Array (Current-Exam).questions | Where-Object { [int]$_.id -eq $Id } | Select-Object -First 1)
}

function Get-ActiveQuestion {
    param([int]$Id)
    return (As-Array (Current-Exam).activeQuestions | Where-Object { [int]$_.id -eq $Id } | Select-Object -First 1)
}

function Get-Participant {
    param([int]$Id)
    return (As-Array (Current-Exam).participants | Where-Object { [int]$_.id -eq $Id } | Select-Object -First 1)
}

function Get-ParticipantByToken {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    return (As-Array (Current-Exam).participants | Where-Object { [string]$_.examToken -eq $Token } | Select-Object -First 1)
}

function Is-Admin {
    param([hashtable]$Headers)
    $token = Get-HeaderValue $Headers "X-Admin-Token"
    if ([string]::IsNullOrWhiteSpace($token)) { return $false }
    return $script:AdminTokens.ContainsKey($token)
}

function Recalculate-Participant {
    param($Participant)

    $answers = As-Array $Participant.answers
    $correct = @($answers | Where-Object { $_.isCorrect -eq $true }).Count
    $answeredWrong = @($answers | Where-Object { $_.isCorrect -eq $false }).Count
    $total = [int]$Participant.totalQuestions

    if ($Participant.status -eq "submitted") {
        $wrong = [math]::Max(0, $total - $correct)
    }
    else {
        $wrong = $answeredWrong
    }

    $score = 0
    if ($total -gt 0) {
        $score = [math]::Round(($correct / $total) * 100, 1)
    }

    $Participant.correctCount = $correct
    $Participant.wrongCount = $wrong
    $Participant.score = $score
}

function Submit-Participant {
    param(
        $Participant,
        [string]$Type,
        [datetime]$At = (Get-Date)
    )

    if ($Participant.status -eq "submitted") { return }

    $Participant.status = "submitted"
    $Participant.submittedAt = Date-ToString $At
    $Participant.submitType = $Type
    Recalculate-Participant $Participant
    Save-Data
}

function Ensure-Timeout {
    param($Participant)

    if ($null -eq $Participant) { return $null }
    $exam = Current-Exam

    if ($Participant.status -eq "in_progress" -and $exam.status -eq "running") {
        if ((Get-Date) -ge (String-ToDate $Participant.expiresAt)) {
            Submit-Participant $Participant "timeout"
        }
    }

    return $Participant
}

function Get-PublicState {
    param($Participant)

    $exam = Current-Exam
    $Participant = Ensure-Timeout $Participant
    $order = As-Array $Participant.questionOrder
    $answers = As-Array $Participant.answers

    $answeredMap = @{}
    foreach ($a in $answers) {
        $answeredMap[[string]$a.questionId] = [bool]$a.isCorrect
    }

    $currentIndex = 0
    if ($Participant.status -eq "in_progress") {
        $found = $false
        for ($i = 0; $i -lt $order.Count; $i++) {
            if (-not $answeredMap.ContainsKey([string]$order[$i])) {
                $currentIndex = $i
                $found = $true
                break
            }
        }
        if (-not $found) { $currentIndex = $order.Count }
    }

    $remaining = 0
    try {
        $remaining = [math]::Max(0, [int][math]::Ceiling(((String-ToDate $Participant.expiresAt) - (Get-Date)).TotalSeconds))
    }
    catch { $remaining = 0 }

    $state = [ordered]@{
        id = $Participant.id
        examId = $exam.id
        name = $Participant.name
        status = $Participant.status
        examStatus = $exam.status
        examName = $exam.name
        scoringMode = (Get-ScoringMode $exam)
        passScore = $exam.passScore
        startedAt = $Participant.startedAt
        expiresAt = $Participant.expiresAt
        submittedAt = $Participant.submittedAt
        submitType = $Participant.submitType
        score = $Participant.score
        correctCount = $Participant.correctCount
        wrongCount = $Participant.wrongCount
        totalQuestions = $Participant.totalQuestions
        remainingSeconds = $remaining
        currentIndex = $currentIndex
    }

    if ($Participant.status -eq "in_progress" -and $currentIndex -lt $order.Count -and $exam.status -eq "running") {
        $qid = [int]$order[$currentIndex]
        $q = Get-ActiveQuestion $qid
        if ($null -ne $q) {
            $state.question = [ordered]@{
                id = $q.id
                position = $q.position
                type = $q.type
                text = $q.text
                options = @(As-Array $q.options)
                media = @(As-Array $q.media)
            }
        }
    }

    return $state
}

function Shuffle-Ids {
    param($Ids)

    $list = New-Object System.Collections.ArrayList
    foreach ($id in $Ids) { [void]$list.Add([int]$id) }
    for ($i = $list.Count - 1; $i -gt 0; $i--) {
        $j = Get-Random -Minimum 0 -Maximum ($i + 1)
        $tmp = $list[$i]
        $list[$i] = $list[$j]
        $list[$j] = $tmp
    }
    return @($list)
}

function Get-ScoringMode {
    param($Exam)
    if ($null -ne $Exam -and $null -ne $Exam.PSObject.Properties["scoringMode"]) {
        $mode = ([string]$Exam.scoringMode).Trim().ToLowerInvariant()
        if ($mode -eq "accuracy" -or $mode -eq "score") { return $mode }
    }
    return "accuracy"
}


function Get-ParticipantElapsedSeconds {
    param($Participant)
    if ($null -eq $Participant) { return 0 }
    try {
        $start = String-ToDate ([string]$Participant.startedAt)
        $finish = Get-Date
        if (-not [string]::IsNullOrWhiteSpace([string]$Participant.submittedAt)) {
            $finish = String-ToDate ([string]$Participant.submittedAt)
        }
        return [math]::Max(0, [int](($finish - $start).TotalSeconds))
    }
    catch { return 0 }
}

function Get-XlsxColumnIndex {
    param([string]$CellReference)
    $letters = ([regex]::Match([string]$CellReference, "^[A-Za-z]+")).Value.ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($letters)) { return -1 }
    $value = 0
    foreach ($ch in $letters.ToCharArray()) {
        $value = ($value * 26) + ([int][char]$ch - [int][char]'A' + 1)
    }
    return $value - 1
}

function Get-XlsxNodeText {
    param($Node)
    if ($null -eq $Node) { return "" }
    $text = New-Object System.Text.StringBuilder
    foreach ($part in $Node.SelectNodes(".//*[local-name()='t']")) { [void]$text.Append($part.InnerText) }
    return $text.ToString()
}

function Read-XlsxImportRecords {
    param([byte[]]$Bytes)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $memory = New-Object System.IO.MemoryStream
    $memory.Write($Bytes, 0, $Bytes.Length)
    $memory.Position = 0
    $zip = New-Object System.IO.Compression.ZipArchive($memory, [System.IO.Compression.ZipArchiveMode]::Read, $false)

    try {
        $sharedStrings = New-Object System.Collections.ArrayList
        $sharedEntry = $zip.GetEntry("xl/sharedStrings.xml")
        if ($null -ne $sharedEntry) {
            $reader = New-Object System.IO.StreamReader($sharedEntry.Open(), [System.Text.Encoding]::UTF8)
            try { [xml]$sharedXml = $reader.ReadToEnd() } finally { $reader.Dispose() }
            foreach ($si in @($sharedXml.SelectNodes("//*[local-name()='si']"))) {
                [void]$sharedStrings.Add((Get-XlsxNodeText $si))
            }
        }

        $workbookEntry = $zip.GetEntry("xl/workbook.xml")
        $relsEntry = $zip.GetEntry("xl/_rels/workbook.xml.rels")
        if ($null -eq $workbookEntry -or $null -eq $relsEntry) { throw "Excel 文件结构无效" }

        $reader = New-Object System.IO.StreamReader($workbookEntry.Open(), [System.Text.Encoding]::UTF8)
        try { [xml]$workbookXml = $reader.ReadToEnd() } finally { $reader.Dispose() }

        # Prefer the input sheet even if reference sheets have been moved to the front.
        $firstSheet = $workbookXml.SelectSingleNode("//*[local-name()='sheets']/*[local-name()='sheet'][@name='Questions']")
        if ($null -eq $firstSheet) {
            foreach ($candidate in $workbookXml.SelectNodes("//*[local-name()='sheets']/*[local-name()='sheet']")) {
                if ([string]$candidate.name -notin @('示例参考','说明','选项列表')) { $firstSheet = $candidate; break }
            }
        }
        if ($null -eq $firstSheet) { throw "Excel 中没有可导入的题目工作表，请填写 Questions 工作表" }

        $relationshipId = ""
        foreach ($attr in @($firstSheet.Attributes)) {
            if ([string]$attr.LocalName -eq "id") { $relationshipId = [string]$attr.Value; break }
        }
        if ([string]::IsNullOrWhiteSpace($relationshipId)) { throw "无法读取 Excel 第一张工作表" }

        $reader = New-Object System.IO.StreamReader($relsEntry.Open(), [System.Text.Encoding]::UTF8)
        try { [xml]$relsXml = $reader.ReadToEnd() } finally { $reader.Dispose() }

        $relationship = $null
        foreach ($rel in @($relsXml.SelectNodes("//*[local-name()='Relationship']"))) {
            if ([string]$rel.Id -eq $relationshipId) { $relationship = $rel; break }
        }
        if ($null -eq $relationship) { throw "Excel 工作表关系不存在" }

        $target = ([string]$relationship.Target).Replace("\", "/")
        if ($target.StartsWith("/")) { $sheetPath = $target.TrimStart("/") }
        elseif ($target.StartsWith("xl/")) { $sheetPath = $target }
        else { $sheetPath = "xl/" + $target }

        $sheetEntry = $zip.GetEntry($sheetPath)
        if ($null -eq $sheetEntry) { throw "无法读取 Excel 第一张工作表数据" }

        $reader = New-Object System.IO.StreamReader($sheetEntry.Open(), [System.Text.Encoding]::UTF8)
        try { [xml]$sheetXml = $reader.ReadToEnd() } finally { $reader.Dispose() }

        $rows = $sheetXml.SelectNodes("/*[local-name()='worksheet']/*[local-name()='sheetData']/*[local-name()='row']")
        if ($rows.Count -eq 0) { return @() }

        $headers = @{}
        $columnIndices = @{}
        $digits = [char[]]"0123456789"
        $records = New-Object System.Collections.ArrayList
        $rowIndex = 0

        foreach ($row in $rows) {
            $cellMap = @{}
            foreach ($cell in $row.ChildNodes) {
                if ($cell.LocalName -ne 'c') { continue }
                $columnName = $cell.GetAttribute('r').TrimEnd($digits)
                if (-not $columnIndices.ContainsKey($columnName)) { $columnIndices[$columnName] = Get-XlsxColumnIndex $columnName }
                $columnIndex = $columnIndices[$columnName]
                if ($columnIndex -lt 0) { continue }
                $cellType = $cell.GetAttribute('t')
                $value = ""
                if ($cellType -eq "inlineStr") {
                    $textNodes = $cell.GetElementsByTagName('t', $cell.NamespaceURI)
                    if ($textNodes.Count -eq 1) { $value = $textNodes[0].InnerText }
                    elseif ($textNodes.Count -gt 1) { $value = Get-XlsxNodeText $cell }
                }
                else {
                    $valueNode = $cell.SelectSingleNode("./*[local-name()='v']")
                    if ($null -ne $valueNode) {
                        $rawValue = [string]$valueNode.InnerText
                        if ($cellType -eq "s") {
                            $sharedIndex = 0
                            if ([int]::TryParse($rawValue, [ref]$sharedIndex) -and $sharedIndex -ge 0 -and $sharedIndex -lt $sharedStrings.Count) {
                                $value = [string]$sharedStrings[$sharedIndex]
                            }
                        }
                        else { $value = $rawValue }
                    }
                }
                $cellMap[$columnIndex] = $value
            }

            if ($rowIndex -eq 0) {
                foreach ($key in @($cellMap.Keys)) {
                    $headerText = ([string]$cellMap[$key]).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($headerText)) { $headers[[int]$key] = $headerText }
                }
            }
            else {
                $record = [ordered]@{}
                $hasValue = $false
                foreach ($key in @($headers.Keys)) {
                    $headerName = [string]$headers[$key]
                    $cellValue = ""
                    if ($cellMap.ContainsKey([int]$key)) { $cellValue = [string]$cellMap[[int]$key] }
                    if (-not [string]::IsNullOrWhiteSpace($cellValue)) { $hasValue = $true }
                    $record[$headerName] = $cellValue
                }
                if ($hasValue) { $record["__sourceRow"] = [int]$row.r; [void]$records.Add([pscustomobject]$record) }
            }
            $rowIndex++
        }
        return $records.ToArray()
    }
    finally {
        $zip.Dispose()
        $memory.Dispose()
    }
}

function Read-CsvImportRecords {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return @() }

    $encoding = [System.Text.Encoding]::UTF8
    $offset = 0
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $encoding = [System.Text.Encoding]::Unicode; $offset = 2
    }
    elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        $encoding = [System.Text.Encoding]::BigEndianUnicode; $offset = 2
    }
    elseif ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $encoding = [System.Text.Encoding]::UTF8; $offset = 3
    }

    $text = $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset)
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return @($text | ConvertFrom-Csv)
}

function Get-ImportField {
    param($Record, [string[]]$Names)
    if ($null -eq $Record) { return "" }
    foreach ($name in $Names) {
        $property = $Record.PSObject.Properties[$name]
        if ($null -ne $property) { return [string]$property.Value }
    }
    return ""
}

function Import-QuestionRecords {
    param($Records, $Exam)

    $recordsArray = @(As-Array $Records)
    $errors = New-Object System.Collections.ArrayList
    $pending = New-Object System.Collections.ArrayList
    $createdAt = Date-ToString (Get-Date)
    $imported = 0
    $rowNumber = 1
    $maxPosition = 0

    foreach ($existingQuestion in (As-Array $Exam.questions)) {
        if ([int]$existingQuestion.position -gt $maxPosition) { $maxPosition = [int]$existingQuestion.position }
    }

    foreach ($record in $recordsArray) {
        $rowNumber++
        if ($null -ne $record.PSObject.Properties["__sourceRow"]) { $rowNumber = [int]$record.__sourceRow }
        $typeRaw = (Get-ImportField $record @("题型", "类型", "type")).Trim()
        $text = Get-ImportField $record @("题目正文", "题目", "question", "text")
        $judgementRaw = (Get-ImportField $record @("判断结果", "判断答案", "正确错误", "result")).Trim()
        $errorText = Get-ImportField $record @("错误部分", "错误文字", "errorText", "error")
        $answerText = Get-ImportField $record @("标准答案", "答案", "answerText", "answer")

        if ([string]::IsNullOrWhiteSpace($text)) { [void]$errors.Add("第 $rowNumber 行：题目正文不能为空"); continue }

        $type = ""
        $typeKey = $typeRaw.ToLowerInvariant()
        if ($typeRaw -in @("判断题", "判断纠错题", "纠错题") -or $typeKey -eq "correction" -or $typeKey -eq "judge" -or $typeKey -eq "judgement") {
            $type = "correction"
        }
        elseif ($typeRaw -eq "主观题" -or $typeKey -eq "subjective") { $type = "subjective" }
        elseif ($typeRaw -eq '选择题' -or $typeKey -eq 'choice') {
            $mode = (Get-ImportField $record @('作答方式','选择类型','choiceMode')).Trim()
            if ($mode -in @('单选','single')) { $type = 'single' }
            elseif ($mode -in @('多选','multiple')) { $type = 'multiple' }
            else { [void]$errors.Add("第 $rowNumber 行：选择题的【作答方式】必须选择【单选】或【多选】"); continue }
        }
        else { [void]$errors.Add("第 $rowNumber 行：题型必须选择【判断题】【主观题】或【选择题】"); continue }

        $noError = $false
        $errorStart = $null
        $errorEnd = $null
        $finalAnswerText = ""
        $options = @()

        if ($type -eq "subjective") {
            $finalAnswerText = ([string]$answerText).Trim()
            if ([string]::IsNullOrWhiteSpace($finalAnswerText)) { [void]$errors.Add("第 $rowNumber 行：主观题必须填写标准答案"); continue }
        }
        elseif ($type -in @('single','multiple')) {
            $options = @(foreach ($key in @('A','B','C','D')) { (Get-ImportField $record @("选项$key", "option$key")).Trim() })
            $finalAnswerText = (Get-ImportField $record @('正确选项','correctOptions')).Trim().Replace('，',',').ToUpperInvariant()
            try { Validate-QuestionExtras @{type=$type; text=$text; options=$options; answerText=$finalAnswerText} }
            catch { [void]$errors.Add("第 $rowNumber 行：$($_.Exception.Message)"); continue }
        }
        else {
            $judgementKey = $judgementRaw.ToLowerInvariant()
            $isCorrectLabel = ($judgementRaw -match "^(正确|对|是)$" -or $judgementKey -eq "true" -or $judgementKey -eq "correct")
            $isWrongLabel = ($judgementRaw -match "^(错误|错|否)$" -or $judgementKey -eq "false" -or $judgementKey -eq "wrong")

            if (-not $isCorrectLabel -and -not $isWrongLabel) {
                [void]$errors.Add("第 $rowNumber 行：判断题的【判断结果】必须填写【正确】或【错误】")
                continue
            }

            if ($isCorrectLabel) { $noError = $true }
            else {
                if ([string]::IsNullOrWhiteSpace([string]$errorText)) { [void]$errors.Add("第 $rowNumber 行：判断结果为【错误】时必须填写【错误部分】"); continue }
                $errorStart = $text.IndexOf([string]$errorText, [System.StringComparison]::Ordinal)
                if ($errorStart -lt 0) { [void]$errors.Add("第 $rowNumber 行：错误部分【$errorText】没有在题目正文中找到"); continue }
                $secondStart = $text.IndexOf([string]$errorText, $errorStart + ([string]$errorText).Length, [System.StringComparison]::Ordinal)
                if ($secondStart -ge 0) { [void]$errors.Add("第 $rowNumber 行：错误部分【$errorText】在题目中出现多次，请调整题目后再导入"); continue }
                $errorEnd = $errorStart + ([string]$errorText).Length
            }
        }

        $script:Data.counters.question = [int]$script:Data.counters.question + 1
        $maxPosition++
        $question = [ordered]@{
            id = [int]$script:Data.counters.question
            position = $maxPosition
            type = $type
            text = [string]$text
            answerText = $(if ($type -ne "correction") { $finalAnswerText } else { "" })
            errorStart = $errorStart
            errorEnd = $errorEnd
            noError = $(if ($type -eq "correction") { [bool]$noError } else { $false })
            enabled = $true
            createdAt = $createdAt
            options = $options
            media = @()
        }
        [void]$pending.Add($question)
        $imported++
    }

    if ($imported -gt 0) {
        $Exam.questions = @($Exam.questions) + $pending.ToArray()
        Save-Data
    }

    return [ordered]@{ importedCount = $imported; totalRows = @($recordsArray).Count; errors = $errors.ToArray() }
}

function Get-QuestionStats {
    param($Exam)

    $participants = @(As-Array $Exam.participants)
    $questions = @(As-Array $Exam.activeQuestions)
    if (@($questions).Count -eq 0) { $questions = @(As-Array $Exam.questions) }

    $stats = @()
    foreach ($q in ($questions | Sort-Object { [int]$_.position })) {
        $correct = 0
        $wrong = 0
        $unanswered = 0
        $considered = 0

        foreach ($p in $participants) {
            $answer = As-Array $p.answers | Where-Object { [int]$_.questionId -eq [int]$q.id } | Select-Object -First 1
            if ($null -ne $answer) {
                $considered++
                if ([bool]$answer.isCorrect) { $correct++ } else { $wrong++ }
            }
            elseif ($p.status -eq "submitted" -or $Exam.status -eq "ended") {
                $considered++
                $unanswered++
            }
            else {
                $unanswered++
            }
        }

        $accuracy = 0
        if ($considered -gt 0) { $accuracy = [math]::Round(($correct / $considered) * 100, 1) }

        $stats += [ordered]@{
            questionId = $q.id
            position = $q.position
            type = $q.type
            text = $q.text
            participantCount = @($participants).Count
            consideredCount = $considered
            correctCount = $correct
            wrongCount = $wrong
            unansweredCount = $unanswered
            accuracy = $accuracy
        }
    }

    return $stats
}

function Get-ExamSummary {
    param($Exam)

    $participants = @(As-Array $Exam.participants)
    $count = @($participants).Count
    $mode = Get-ScoringMode $Exam
    $passed = 0
    if ($mode -eq "score") {
        $passed = @($participants | Where-Object { [double]$_.score -ge [double]$Exam.passScore }).Count
    }

    $avg = 0
    if ($count -gt 0) {
        $sum = 0.0
        foreach ($p in $participants) { $sum += [double]$p.score }
        $avg = [math]::Round($sum / $count, 1)
    }

    return [ordered]@{
        id = $Exam.id
        name = $Exam.name
        status = $Exam.status
        scoringMode = $mode
        createdAt = $Exam.createdAt
        startedAt = $Exam.startedAt
        endedAt = $Exam.endedAt
        durationMinutes = $Exam.durationMinutes
        passScore = $Exam.passScore
        questionCount = @((As-Array $Exam.activeQuestions)).Count
        participantCount = $count
        averageScore = $avg
        averageAccuracy = $avg
        passedCount = $passed
        failedCount = $(if ($mode -eq "score") { [math]::Max(0, $count - $passed) } else { 0 })
    }
}

function Archive-CurrentExam {
    $exam = Current-Exam
    $archive = Deep-Clone $exam
    $path = Join-Path $HistoryDir ($archive.id + ".json")
    Save-JsonFile $path $archive
}

function Load-HistoryExam {
    param([string]$Id)

    if ($Id -notmatch "^[A-Za-z0-9_-]+$") { return $null }
    $path = Join-Path $HistoryDir ($Id + ".json")
    if (-not (Test-Path $path)) { return $null }
    try {
        return ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
    catch { return $null }
}

function Find-HistoryParticipantByToken {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }

    foreach ($file in (Get-ChildItem -Path $HistoryDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        try {
            $exam = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $participant = As-Array $exam.participants | Where-Object { [string]$_.examToken -eq $Token } | Select-Object -First 1
            if ($null -ne $participant) {
                return [ordered]@{ exam = $exam; participant = $participant }
            }
        }
        catch { }
    }

    return $null
}

function Get-HistoryResultState {
    param($Exam, $Participant)

    return [ordered]@{
        id = $Participant.id
        examId = $Exam.id
        name = $Participant.name
        status = "submitted"
        examStatus = "ended"
        examName = $Exam.name
        scoringMode = (Get-ScoringMode $Exam)
        passScore = $Exam.passScore
        startedAt = $Participant.startedAt
        expiresAt = $Participant.expiresAt
        submittedAt = $Participant.submittedAt
        submitType = $Participant.submitType
        score = $Participant.score
        correctCount = $Participant.correctCount
        wrongCount = $Participant.wrongCount
        totalQuestions = $Participant.totalQuestions
        remainingSeconds = 0
        currentIndex = $Participant.totalQuestions
    }
}

function Get-HistoryList {
    $items = @()
    foreach ($file in (Get-ChildItem -Path $HistoryDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        try {
            $exam = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $items += Get-ExamSummary $exam
        }
        catch { }
    }
    return @($items | Sort-Object endedAt -Descending)
}

function Xml-Escape {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return [System.Security.SecurityElement]::Escape($Text)
}

function Excel-ColName {
    param([int]$Number)
    $name = ""
    while ($Number -gt 0) {
        $Number--
        $name = [char](65 + ($Number % 26)) + $name
        $Number = [math]::Floor($Number / 26)
    }
    return $name
}

function New-WorksheetXml {
    param($Rows)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')

    $rowNumber = 1
    foreach ($row in $Rows) {
        [void]$sb.Append('<row r="' + $rowNumber + '">')
        $colNumber = 1
        foreach ($cell in $row) {
            $ref = (Excel-ColName $colNumber) + $rowNumber
            if ($cell -is [int] -or $cell -is [long] -or $cell -is [double] -or $cell -is [decimal]) {
                [void]$sb.Append('<c r="' + $ref + '"><v>' + ([string]$cell) + '</v></c>')
            }
            else {
                $text = Xml-Escape ([string]$cell)
                [void]$sb.Append('<c r="' + $ref + '" t="inlineStr"><is><t xml:space="preserve">' + $text + '</t></is></c>')
            }
            $colNumber++
        }
        [void]$sb.Append('</row>')
        $rowNumber++
    }

    [void]$sb.Append('</sheetData></worksheet>')
    return $sb.ToString()
}

function Get-QuestionExportText {
    param($Question)
    $lines = @([string]$Question.text)
    $options = @(As-Array $Question.options)
    for ($i = 0; $i -lt $options.Count; $i++) { $lines += ([string][char](65 + $i)) + '. ' + [string]$options[$i] }
    foreach ($m in (As-Array $Question.media)) { $lines += '[图片/附件] ' + [string]$m.name }
    return ($lines -join "`n")
}

function Build-XlsxBytes {
    param($Exam)

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("lan_exam_xlsx_" + [Guid]::NewGuid().ToString("N"))
    $xlDir = Join-Path $tempRoot "xl"
    $wsDir = Join-Path $xlDir "worksheets"
    $relsDir = Join-Path $tempRoot "_rels"
    $xlRelsDir = Join-Path $xlDir "_rels"

    New-Item -ItemType Directory -Path $wsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $relsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $xlRelsDir -Force | Out-Null

    $summary = Get-ExamSummary $Exam
    $scoringMode = Get-ScoringMode $Exam
    $scoringLabel = $(if ($scoringMode -eq "score") { "百分制" } else { "只统计正确率" })
    $passLine = $(if ($scoringMode -eq "score") { [double]$Exam.passScore } else { "未启用" })
    $passedLine = $(if ($scoringMode -eq "score") { [int]$summary.passedCount } else { "-" })
    $failedLine = $(if ($scoringMode -eq "score") { [int]$summary.failedCount } else { "-" })

    $summaryRows = @(
        @("项目", "内容"),
        @("考试名称", $Exam.name),
        @("考试ID", $Exam.id),
        @("开始时间", $Exam.startedAt),
        @("结束时间", $Exam.endedAt),
        @("考试时长（分钟）", [int]$Exam.durationMinutes),
        @("统计方式", $scoringLabel),
        @("及格线", $passLine),
        @("题目数量", [int]$summary.questionCount),
        @("参加人数", [int]$summary.participantCount),
        @("平均正确率(%)", [double]$summary.averageAccuracy),
        @("通过人数", $passedLine),
        @("未通过人数", $failedLine)
    )

    $memberRows = @()
    $memberRows += ,@("排名", "姓名", "IP", "正确率(%)", "成绩", "是否通过", "正确题数", "错误/未答题数", "开始时间", "交卷时间", "实际用时", "交卷方式")

    $rankedParticipants = @(
        As-Array $Exam.participants |
            Sort-Object @{ Expression = { [double]$_.score }; Descending = $true }, @{ Expression = { Get-ParticipantElapsedSeconds $_ }; Ascending = $true }, @{ Expression = { [string]$_.name }; Ascending = $true }
    )
    $rankNumber = 0
    foreach ($p in $rankedParticipants) {
        $rankNumber++
        $elapsed = ""
        try {
            $seconds = Get-ParticipantElapsedSeconds $p
            $elapsed = (New-TimeSpan -Seconds $seconds).ToString()
        }
        catch { }

        $scoreValue = "-"
        $passResult = "-"
        if ($scoringMode -eq "score") {
            $scoreValue = [double]$p.score
            if ([double]$p.score -ge [double]$Exam.passScore) { $passResult = "通过" } else { $passResult = "未通过" }
        }

        $submitType = switch ([string]$p.submitType) {
            "manual" { "主动交卷" }
            "timeout" { "超时自动交卷" }
            "completed" { "全部题目完成" }
            "admin_end" { "管理员结束考试" }
            default { [string]$p.submitType }
        }

        $memberRows += ,@(
            $rankNumber,
            $p.name,
            $p.clientIp,
            [double]$p.score,
            $scoreValue,
            $passResult,
            [int]$p.correctCount,
            [int]$p.wrongCount,
            $p.startedAt,
            $p.submittedAt,
            $elapsed,
            $submitType
        )
    }

    $detailRows = @()
    $detailRows += ,@("姓名", "管理员题号", "成员实际顺序", "题型", "题目", "成员答案", "标准答案/错误部分", "结果", "作答时间")

    $questionMap = @{}
    foreach ($q in (As-Array $Exam.activeQuestions)) { $questionMap[[string]$q.id] = $q }

    foreach ($p in (As-Array $Exam.participants)) {
        $answerMap = @{}
        foreach ($a in (As-Array $p.answers)) { $answerMap[[string]$a.questionId] = $a }

        $order = As-Array $p.questionOrder
        for ($i = 0; $i -lt $order.Count; $i++) {
            $qid = [string]$order[$i]
            if (-not $questionMap.ContainsKey($qid)) { continue }
            $q = $questionMap[$qid]
            $a = $null
            if ($answerMap.ContainsKey($qid)) { $a = $answerMap[$qid] }

            $userAnswer = "未作答"
            $result = "未作答"
            $answeredAt = ""

            if ($null -ne $a) {
                $answeredAt = $a.answeredAt
                if ($q.type -ne "correction") {
                    $userAnswer = [string]$a.userAnswer
                }
                elseif ([string]$a.userAnswer -eq "本题无错误") {
                    $userAnswer = "本题无错误"
                }
                else {
                    [int]$idx = -1
                    if ([int]::TryParse([string]$a.userAnswer, [ref]$idx) -and $idx -ge 0 -and $idx -lt $q.text.Length) {
                        $userAnswer = "点击字符：" + (Get-SafeClickedCharacter $q $idx)
                    }
                    else {
                        $userAnswer = [string]$a.userAnswer
                    }
                }
                $result = $(if ([bool]$a.isCorrect) { "正确" } else { "错误" })
            }

            if ($q.type -ne "correction") {
                $standard = [string]$q.answerText
                $typeName = $(switch ($q.type) { single { "单选题" } multiple { "多选题" } default { "主观题" } })
            }
            else {
                $typeName = "判断纠错题"
                if ([bool]$q.noError) {
                    $standard = "本题无错误"
                }
                else {
                    $standard = (Get-SafeCorrectionText $q)
                }
            }

            $detailRows += ,@(
                $p.name,
                [int]$q.position,
                $i + 1,
                $typeName,
                (Get-QuestionExportText $q),
                $userAnswer,
                $standard,
                $result,
                $answeredAt
            )
        }
    }

    $questionAnalysisRows = @()
    $questionAnalysisRows += ,@("题号", "题型", "题目", "正确人数", "错误人数", "未作答人数", "正确率(%)")
    foreach ($stat in (Get-QuestionStats $Exam)) {
        $typeName = $(switch ($stat.type) { single { "单选题" } multiple { "多选题" } subjective { "主观题" } default { "判断纠错题" } })
        $questionAnalysisRows += ,@(
            [int]$stat.position,
            $typeName,
            $stat.text,
            [int]$stat.correctCount,
            [int]$stat.wrongCount,
            [int]$stat.unansweredCount,
            [double]$stat.accuracy
        )
    }

    $contentTypes = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/worksheets/sheet3.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/worksheets/sheet4.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>
'@

    $rootRels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
'@

    $workbook = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets>
<sheet name="考试汇总" sheetId="1" r:id="rId1"/>
<sheet name="成员成绩" sheetId="2" r:id="rId2"/>
<sheet name="答题详情" sheetId="3" r:id="rId3"/>
<sheet name="题目分析" sheetId="4" r:id="rId4"/>
</sheets>
</workbook>
'@

    $workbookRels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/>
<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet4.xml"/>
</Relationships>
'@

    Save-TextUtf8NoBom (Join-Path $tempRoot "[Content_Types].xml") $contentTypes
    Save-TextUtf8NoBom (Join-Path $relsDir ".rels") $rootRels
    Save-TextUtf8NoBom (Join-Path $xlDir "workbook.xml") $workbook
    Save-TextUtf8NoBom (Join-Path $xlRelsDir "workbook.xml.rels") $workbookRels
    Save-TextUtf8NoBom (Join-Path $wsDir "sheet1.xml") (New-WorksheetXml $summaryRows)
    Save-TextUtf8NoBom (Join-Path $wsDir "sheet2.xml") (New-WorksheetXml $memberRows)
    Save-TextUtf8NoBom (Join-Path $wsDir "sheet3.xml") (New-WorksheetXml $detailRows)
    Save-TextUtf8NoBom (Join-Path $wsDir "sheet4.xml") (New-WorksheetXml $questionAnalysisRows)

    $xlsxPath = Join-Path ([System.IO.Path]::GetTempPath()) ("exam_" + $Exam.id + "_results.xlsx")
    if (Test-Path $xlsxPath) { Remove-Item $xlsxPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempRoot, $xlsxPath)
    $bytes = [System.IO.File]::ReadAllBytes($xlsxPath)

    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $xlsxPath -Force -ErrorAction SilentlyContinue

    return $bytes
}

function Save-TextUtf8NoBom {
    param(
        [string]$Path,
        [string]$Text
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Get-LanIPv4 {
    try {
        $items = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
            Sort-Object InterfaceMetric
        if ($items.Count -gt 0) { return [string]$items[0].IPAddress }
    }
    catch { }

    try {
        $entry = [System.Net.Dns]::GetHostEntry([System.Net.Dns]::GetHostName())
        $ip = $entry.AddressList |
            Where-Object {
                $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                $_.ToString() -notlike "127.*"
            } |
            Select-Object -First 1
        if ($null -ne $ip) { return $ip.ToString() }
    }
    catch { }

    return "127.0.0.1"
}

function Read-HttpRequest {
    param([System.Net.Sockets.NetworkStream]$Stream)

    $headerBytes = New-Object System.Collections.Generic.List[byte]
    $state = 0

    while ($true) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) { break }
        $headerBytes.Add([byte]$value)

        if ($state -eq 0 -and $value -eq 13) { $state = 1 }
        elseif ($state -eq 1 -and $value -eq 10) { $state = 2 }
        elseif ($state -eq 2 -and $value -eq 13) { $state = 3 }
        elseif ($state -eq 3 -and $value -eq 10) { break }
        elseif ($value -eq 13) { $state = 1 }
        else { $state = 0 }

        if ($headerBytes.Count -gt 65536) { throw "HTTP header too large" }
    }

    if ($headerBytes.Count -eq 0) { return $null }

    $headerText = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
    $lines = $headerText -split "`r`n"
    $first = $lines[0] -split " "
    if ($first.Count -lt 2) { throw "Bad HTTP request" }

    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
        $colon = $lines[$i].IndexOf(":")
        if ($colon -gt 0) {
            $headers[$lines[$i].Substring(0, $colon).Trim()] = $lines[$i].Substring($colon + 1).Trim()
        }
    }

    $contentLength = 0
    $lengthHeader = Get-HeaderValue $headers "Content-Length"
    if (-not [string]::IsNullOrWhiteSpace($lengthHeader)) {
        [void][int]::TryParse($lengthHeader, [ref]$contentLength)
    }

    if ($contentLength -lt 0 -or $contentLength -gt 16MB) { throw "请求体过大" }
    $bodyBytes = New-Object byte[] $contentLength
    $read = 0
    while ($read -lt $contentLength) {
        $count = $Stream.Read($bodyBytes, $read, $contentLength - $read)
        if ($count -le 0) { break }
        $read += $count
    }

    $body = ""
    if ($contentLength -gt 0) {
        $body = [System.Text.Encoding]::UTF8.GetString($bodyBytes, 0, $read)
    }

    $target = $first[1]
    $query = ""
    $queryIndex = $target.IndexOf("?")
    if ($queryIndex -ge 0) {
        $query = $target.Substring($queryIndex + 1)
        $target = $target.Substring(0, $queryIndex)
    }

    return [ordered]@{
        method = $first[0].ToUpperInvariant()
        path = [System.Uri]::UnescapeDataString($target)
        query = $query
        headers = $headers
        body = $body
    }
}

function Write-Response {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$Status,
        [string]$ContentType,
        [byte[]]$BodyBytes,
        [hashtable]$ExtraHeaders = $null
    )

    $statusText = switch ($Status) {
        200 { "OK" }
        201 { "Created" }
        400 { "Bad Request" }
        401 { "Unauthorized" }
        403 { "Forbidden" }
        404 { "Not Found" }
        409 { "Conflict" }
        500 { "Internal Server Error" }
        default { "OK" }
    }

    $header = "HTTP/1.1 $Status $statusText`r`n"
    $header += "Content-Type: $ContentType`r`n"
    $header += "Content-Length: $($BodyBytes.Length)`r`n"
    $header += "Cache-Control: no-store`r`n"
    $header += "Connection: close`r`n"

    if ($null -ne $ExtraHeaders) {
        foreach ($key in $ExtraHeaders.Keys) {
            $header += "$key`: $($ExtraHeaders[$key])`r`n"
        }
    }

    $header += "`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($BodyBytes.Length -gt 0) { $Stream.Write($BodyBytes, 0, $BodyBytes.Length) }
    $Stream.Flush()
}

function Write-Json {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$Status,
        $Object
    )
    $json = $Object | ConvertTo-Json -Depth 40 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Write-Response $Stream $Status "application/json; charset=utf-8" $bytes
}

function Serve-File {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) {
        Write-Response $Stream 404 "text/plain; charset=utf-8" ([System.Text.Encoding]::UTF8.GetBytes("Not Found"))
        return
    }

    Write-Response $Stream 200 "text/html; charset=utf-8" ([System.IO.File]::ReadAllBytes($FilePath))
}

function Compact-DraftPositions {
    $exam = Current-Exam
    $questions = @(As-Array $exam.questions | Sort-Object { [int]$_.position }, { [int]$_.id })
    for ($i = 0; $i -lt $questions.Count; $i++) { $questions[$i].position = $i + 1 }
    $exam.questions = $questions
}

function Require-Draft {
    param([System.Net.Sockets.NetworkStream]$Stream)
    if ((Current-Exam).status -ne "draft") {
        Write-Json $Stream 409 @{ ok = $false; message = "只有未开始的考试可以修改设置和题目" }
        return $false
    }
    return $true
}

function Validate-QuestionExtras {
    param($Body)
    if ([string]$Body.type -notin @('correction','subjective','single','multiple')) { throw '题型无效' }
    $media = @(As-Array $Body.media)
    if ($media.Count -gt 6) { throw '每题最多上传 6 个文件' }
    $total = 0
    foreach ($m in $media) {
        if ([string]$Body.type -eq 'correction') { throw '判断题不支持上传文件' }
        if ([string]::IsNullOrWhiteSpace([string]$m.name) -or ([string]$m.name).Length -gt 200) { throw '文件名无效' }
        if ([string]$m.data -match '^/media/([a-f0-9]{32}\.(png|jpg|gif|webp|bin))$') {
            $file = Join-Path $MediaDir $Matches[1]
            if (-not (Test-Path -LiteralPath $file)) { throw '题目文件不存在，请重新上传' }
            $total += (Get-Item -LiteralPath $file).Length
            if ($total -gt 6MB) { throw '每题文件合计最多 6MB' }
            continue
        }
        if ([string]$m.data -notmatch '^data:(image/png|image/jpeg|image/gif|image/webp|application/octet-stream);base64,([A-Za-z0-9+/=]+)$') { throw '文件格式无效' }
        $mime = $Matches[1]
        $bytes = [Convert]::FromBase64String($Matches[2])
        $total += $bytes.Length
        if ($bytes.Length -gt 3MB -or $total -gt 6MB) { throw '单个文件最多 3MB，每题合计最多 6MB' }
        if ($mime -eq 'application/octet-stream' -and [IO.Path]::GetExtension([string]$m.name).ToLowerInvariant() -notin @('.pdf','.doc','.docx','.xls','.xlsx','.txt','.csv','.zip')) { throw '不支持的附件格式' }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Body.text) -and @($media | Where-Object { [string]$_.data -match '^(data:image/|/media/[a-f0-9]{32}\.(png|jpg|gif|webp)$)' }).Count -eq 0) { throw '请填写题目正文或上传题目图片' }
    if ([string]$Body.type -in @('single','multiple')) {
        $options = @(As-Array $Body.options)
        if ($options.Count -ne 4) { throw '选择题必须填写 A、B、C、D 四个选项' }
        foreach ($option in $options) { if ([string]::IsNullOrWhiteSpace([string]$option)) { throw '选项不能为空' } }
        $keys = ([string]$Body.answerText).Split(',')
        if (($keys | Select-Object -Unique).Count -ne $keys.Count) { throw '答案不能重复' }
        foreach ($key in $keys) { if ($key -notmatch '^[A-D]$' -or ([int][char]$key - 65) -ge $options.Count) { throw '正确答案无效' } }
        if ([string]$Body.type -eq 'single' -and $keys.Count -ne 1) { throw '单选题只能设置一个正确答案' }
        if ([string]$Body.type -eq 'multiple' -and $keys.Count -lt 2) { throw '多选题至少设置两个正确答案' }
    }
}

function Set-QuestionExtras {
    param($Question,$Body)
    foreach ($name in @('options','media')) {
        $value = @(As-Array $Body.$name)
        if ($name -eq 'options' -and [string]$Body.type -notin @('single','multiple')) { $value = @() }
        if ($name -eq 'media') {
            $stored = @()
            foreach ($m in $value) {
                $url = [string]$m.data
                if ($url -match '^data:([^;]+);base64,(.+)$') {
                    $mime = $Matches[1]
                    $bytes = [Convert]::FromBase64String($Matches[2])
                    $ext = switch ($mime) { 'image/png' { 'png' } 'image/jpeg' { 'jpg' } 'image/gif' { 'gif' } 'image/webp' { 'webp' } default { 'bin' } }
                    $fileName = [Guid]::NewGuid().ToString('N') + '.' + $ext
                    [IO.File]::WriteAllBytes((Join-Path $MediaDir $fileName), $bytes)
                    $url = '/media/' + $fileName
                }
                $size = (Get-Item -LiteralPath (Join-Path $MediaDir ($url.Substring(7)))).Length
                $stored += [ordered]@{ name = [string]$m.name; data = $url; size = $size }
            }
            $value = $stored
        }
        if ($Question -is [System.Collections.IDictionary]) { $Question[$name] = $value }
        else { $Question | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
    }
}

function Handle-Request {
    param(
        $Request,
        [System.Net.Sockets.NetworkStream]$Stream,
        [string]$ClientIp
    )

    $method = $Request.method
    $path = $Request.path
    $body = Parse-JsonBody $Request.body
    $exam = Current-Exam

    # Random file URLs act as download capabilities; only administrators can create references.
    if ($method -eq 'GET' -and $path -match '^/media/([a-f0-9]{32}\.(png|jpg|gif|webp|bin))$') {
        $file = Join-Path $MediaDir $Matches[1]
        $ext = $Matches[2]
        if (-not (Test-Path -LiteralPath $file)) { Write-Json $Stream 404 @{ ok = $false; message = '文件不存在' }; return }
        $mime = switch ($ext) { png { 'image/png' } jpg { 'image/jpeg' } gif { 'image/gif' } webp { 'image/webp' } default { 'application/octet-stream' } }
        $headers = @{ 'X-Content-Type-Options' = 'nosniff'; 'Cache-Control' = 'private, max-age=3600' }
        if ($ext -eq 'bin') { $headers['Content-Disposition'] = 'attachment' }
        Write-Response $Stream 200 $mime ([IO.File]::ReadAllBytes($file)) $headers
        return
    }

    if ($method -eq "GET" -and $path -eq "/") {
        Serve-File $Stream (Join-Path $WebDir "user.html")
        return
    }

    if ($method -eq "GET" -and $path -eq "/admin") {
        Serve-File $Stream (Join-Path $WebDir "admin.html")
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/health") {
        Write-Json $Stream 200 @{ ok = $true; message = "running"; version = "0.1.0" }
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/admin/login") {
        if (
            $null -ne $body -and
            [string]$body.username -eq [string]$script:Data.admin.user -and
            [string]$body.password -eq [string]$script:Data.admin.password
        ) {
            $token = New-Token
            $script:AdminTokens[$token] = $true
            Write-Json $Stream 200 @{ ok = $true; token = $token }
            return
        }
        Write-Json $Stream 401 @{ ok = $false; message = "用户名或密码错误" }
        return
    }

    if ($path.StartsWith("/api/admin/") -and -not (Is-Admin $Request.headers)) {
        Write-Json $Stream 401 @{ ok = $false; message = "管理员未登录" }
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/admin/exam") {
        Write-Json $Stream 200 @{
            ok = $true
            exam = $exam
            summary = (Get-ExamSummary $exam)
        }
        return
    }

    if ($method -eq "PUT" -and $path -eq "/api/admin/exam") {
        if (-not (Require-Draft $Stream)) { return }
        if ($null -eq $body) {
            Write-Json $Stream 400 @{ ok = $false; message = "参数错误" }
            return
        }

        $name = ([string]$body.name).Trim()
        $code = ([string]$body.accessCode).Trim()
        $duration = [int]$body.durationMinutes
        $mode = [string]$body.scoringMode
        if ($mode -ne "score") { $mode = "accuracy" }
        $pass = [double]$body.passScore

        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Json $Stream 400 @{ ok = $false; message = "考试名称不能为空" }
            return
        }
        if ([string]::IsNullOrWhiteSpace($code)) {
            Write-Json $Stream 400 @{ ok = $false; message = "考试口令不能为空" }
            return
        }
        if ($duration -lt 1 -or $duration -gt 1440) {
            Write-Json $Stream 400 @{ ok = $false; message = "考试时长需在 1~1440 分钟之间" }
            return
        }
        if ($mode -eq "score" -and ($pass -lt 0 -or $pass -gt 100)) {
            Write-Json $Stream 400 @{ ok = $false; message = "及格分需在 0~100 之间" }
            return
        }

        $exam.name = $name
        $exam.accessCode = $code
        $exam.durationMinutes = $duration
        $exam.scoringMode = $mode
        $exam.passScore = $pass
        $exam.randomizeQuestions = [bool]$body.randomizeQuestions

        if (-not [string]::IsNullOrWhiteSpace([string]$body.adminPassword)) {
            $script:Data.admin.password = [string]$body.adminPassword
        }

        Save-Data
        Write-Json $Stream 200 @{ ok = $true }
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/admin/exam/start") {
        if ($exam.status -ne "draft") {
            Write-Json $Stream 409 @{ ok = $false; message = "当前考试不是未开始状态" }
            return
        }

        $selected = @(As-Array $exam.questions | Sort-Object { [int]$_.position }, { [int]$_.id })
        if ($selected.Count -eq 0) {
            Write-Json $Stream 400 @{ ok = $false; message = "至少添加一道考试题目" }
            return
        }

        $exam.activeQuestions = Deep-Clone $selected
        $exam.status = "running"
        $exam.startedAt = Date-ToString (Get-Date)
        $exam.endedAt = ""
        $exam.participants = @()
        Save-Data

        Write-Json $Stream 200 @{ ok = $true; exam = $exam }
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/admin/exam/end") {
        if ($exam.status -ne "running") {
            Write-Json $Stream 409 @{ ok = $false; message = "只有进行中的考试可以结束" }
            return
        }

        $endTime = Get-Date
        foreach ($p in (As-Array $exam.participants)) {
            if ($p.status -eq "in_progress") {
                Submit-Participant $p "admin_end" $endTime
            }
        }

        $exam.status = "ended"
        $exam.endedAt = Date-ToString $endTime
        Save-Data
        Archive-CurrentExam

        Write-Json $Stream 200 @{
            ok = $true
            exam = $exam
            summary = (Get-ExamSummary $exam)
        }
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/admin/exam/new") {
        if ($exam.status -ne "ended") {
            Write-Json $Stream 409 @{ ok = $false; message = "请先结束当前考试，再创建下一场" }
            return
        }

        $newExamParams = @{
            Name = "新考试"
            DurationMinutes = [int]$exam.durationMinutes
            PassScore = [double]$exam.passScore
            AccessCode = [string]$exam.accessCode
            RandomizeQuestions = [bool]$exam.randomizeQuestions
            ScoringMode = (Get-ScoringMode $exam)
        }

        $script:Data.currentExam = New-DraftExam @newExamParams

        Save-Data
        Write-Json $Stream 200 @{ ok = $true; exam = $script:Data.currentExam }
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/admin/questions") {
        Write-Json $Stream 200 @{ ok = $true; questions = @(As-Array $exam.questions | Sort-Object { [int]$_.position }, { [int]$_.id }) }
        return
    }


    if ($method -eq "GET" -and $path -eq "/api/admin/questions/import-template.xlsx") {
        if (-not (Require-Draft $Stream)) { return }
        $templatePath = Join-Path $BaseDir "QUESTION_IMPORT_TEMPLATE.xlsx"
        if (-not (Test-Path $templatePath)) { Write-Json $Stream 404 @{ ok = $false; message = "导入模板不存在" }; return }
        $templateBytes = [System.IO.File]::ReadAllBytes($templatePath)
        Write-Response $Stream 200 "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" $templateBytes @{
            "Content-Disposition" = "attachment; filename=question_import_template.xlsx"
        }
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/admin/questions/import") {
        if (-not (Require-Draft $Stream)) { return }
        if ($null -eq $body) { Write-Json $Stream 400 @{ ok = $false; message = "导入参数错误" }; return }

        $fileName = ([string]$body.fileName).Trim()
        $base64 = [string]$body.dataBase64
        if ([string]::IsNullOrWhiteSpace($fileName) -or [string]::IsNullOrWhiteSpace($base64)) {
            Write-Json $Stream 400 @{ ok = $false; message = "请选择 Excel 或 CSV 文件" }
            return
        }

        try { $bytes = [Convert]::FromBase64String($base64) }
        catch { Write-Json $Stream 400 @{ ok = $false; message = "文件内容无效" }; return }

        if ($bytes.Length -gt 10MB) { Write-Json $Stream 400 @{ ok = $false; message = "导入文件请不要超过 10MB" }; return }
        try {
            $extension = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()
            if ($extension -eq ".xlsx") { $records = @(Read-XlsxImportRecords $bytes) }
            elseif ($extension -eq ".csv") { $records = @(Read-CsvImportRecords $bytes) }
            else { Write-Json $Stream 400 @{ ok = $false; message = "仅支持 .xlsx 或 .csv 文件" }; return }

            if (@($records).Count -eq 0) { Write-Json $Stream 400 @{ ok = $false; message = "文件中没有可导入的正式题目，请填写题目后再导入（示例参考不参与导入）" }; return }

            $result = Import-QuestionRecords $records $exam
            Write-Json $Stream 200 @{ ok = $true; importedCount = $result.importedCount; totalRows = $result.totalRows; errors = @($result.errors) }
        }
        catch {
            Write-Json $Stream 500 @{ ok = $false; message = "题目导入失败"; detail = $_.Exception.Message }
        }
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/admin/questions") {
        if (-not (Require-Draft $Stream)) { return }
        if ($null -eq $body) {
            Write-Json $Stream 400 @{ ok = $false; message = "参数错误" }
            return
        }

        $type = [string]$body.type
        $text = [string]$body.text
        if ($type -notin @('correction','subjective','single','multiple')) {
            Write-Json $Stream 400 @{ ok = $false; message = "题型无效" }
            return
        }
        try { Validate-QuestionExtras $body } catch { Write-Json $Stream 400 @{ ok = $false; message = $_.Exception.Message }; return }

        $answerText = ([string]$body.answerText).Trim()
        $noError = [bool]$body.noError
        $errorStart = $null
        $errorEnd = $null

        if ($type -eq "subjective" -and [string]::IsNullOrWhiteSpace($answerText)) {
            Write-Json $Stream 400 @{ ok = $false; message = "主观题标准答案不能为空" }
            return
        }

        if ($type -eq "correction" -and -not $noError) {
            if ($null -eq $body.errorStart -or $null -eq $body.errorEnd) {
                Write-Json $Stream 400 @{ ok = $false; message = "请先设置错误文字" }
                return
            }
            $errorStart = [int]$body.errorStart
            $errorEnd = [int]$body.errorEnd
            if ($errorStart -lt 0 -or $errorEnd -le $errorStart -or $errorEnd -gt $text.Length) {
                Write-Json $Stream 400 @{ ok = $false; message = "错误文字范围无效" }
                return
            }
        }

        $script:Data.counters.question = [int]$script:Data.counters.question + 1
        $maxPosition = 0
        foreach ($q0 in (As-Array $exam.questions)) {
            if ([int]$q0.position -gt $maxPosition) { $maxPosition = [int]$q0.position }
        }

        $q = [ordered]@{
            id = [int]$script:Data.counters.question
            position = $maxPosition + 1
            type = $type
            text = $text
            answerText = $(if ($type -ne "correction") { $answerText } else { "" })
            errorStart = $errorStart
            errorEnd = $errorEnd
            noError = $(if ($type -eq "correction") { $noError } else { $false })
            enabled = $true
            createdAt = (Date-ToString (Get-Date))
        }

        Set-QuestionExtras $q $body
        $exam.questions = @(As-Array $exam.questions) + @($q)
        Save-Data
        Write-Json $Stream 201 @{ ok = $true; id = $q.id }
        return
    }

    if ($path -match "^/api/admin/questions/(\d+)$") {
        if (-not (Require-Draft $Stream)) { return }
        $qid = [int]$Matches[1]
        $q = Get-DraftQuestion $qid
        if ($null -eq $q) {
            Write-Json $Stream 404 @{ ok = $false; message = "题目不存在" }
            return
        }

        if ($method -eq "DELETE") {
            $exam.questions = @(As-Array $exam.questions | Where-Object { [int]$_.id -ne $qid })
            Compact-DraftPositions
            Save-Data
            Write-Json $Stream 200 @{ ok = $true }
            return
        }

        if ($method -eq "PUT") {
            $type = [string]$body.type
            $text = [string]$body.text
            $answerText = ([string]$body.answerText).Trim()
            $noError = [bool]$body.noError
            $errorStart = $null
            $errorEnd = $null

            try { Validate-QuestionExtras $body } catch { Write-Json $Stream 400 @{ ok = $false; message = $_.Exception.Message }; return }
            if ($type -eq "subjective" -and [string]::IsNullOrWhiteSpace($answerText)) {
                Write-Json $Stream 400 @{ ok = $false; message = "主观题标准答案不能为空" }
                return
            }
            if ($type -eq "correction" -and -not $noError) {
                if ($null -eq $body.errorStart -or $null -eq $body.errorEnd) {
                    Write-Json $Stream 400 @{ ok = $false; message = "请先设置错误文字" }
                    return
                }
                $errorStart = [int]$body.errorStart
                $errorEnd = [int]$body.errorEnd
                if ($errorStart -lt 0 -or $errorEnd -le $errorStart -or $errorEnd -gt $text.Length) {
                    Write-Json $Stream 400 @{ ok = $false; message = "错误文字范围无效，请重新选择错误位置" }
                    return
                }
            }

            $q.type = $type
            $q.text = $text
            $q.answerText = $(if ($type -ne "correction") { $answerText } else { "" })
            $q.errorStart = $errorStart
            $q.errorEnd = $errorEnd
            $q.noError = $(if ($type -eq "correction") { $noError } else { $false })
            $q.enabled = $true
            Set-QuestionExtras $q $body

            Save-Data
            Write-Json $Stream 200 @{ ok = $true }
            return
        }
    }

    if ($path -match "^/api/admin/questions/(\d+)/move$" -and $method -eq "POST") {
        if (-not (Require-Draft $Stream)) { return }
        $qid = [int]$Matches[1]
        $questions = @(As-Array $exam.questions | Sort-Object { [int]$_.position }, { [int]$_.id })
        $index = -1
        for ($i = 0; $i -lt $questions.Count; $i++) {
            if ([int]$questions[$i].id -eq $qid) { $index = $i; break }
        }

        if ($index -ge 0) {
            $target = $(if ([string]$body.direction -eq "up") { $index - 1 } else { $index + 1 })
            if ($target -ge 0 -and $target -lt $questions.Count) {
                $tmp = $questions[$index]
                $questions[$index] = $questions[$target]
                $questions[$target] = $tmp
                for ($i = 0; $i -lt $questions.Count; $i++) { $questions[$i].position = $i + 1 }
                $exam.questions = $questions
                Save-Data
            }
        }

        Write-Json $Stream 200 @{ ok = $true }
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/admin/participants") {
        $result = @()
        foreach ($p in (As-Array $exam.participants | Sort-Object startedAt -Descending)) {
            $p = Ensure-Timeout $p
            $end = Get-Date
            if ($p.status -eq "submitted" -and -not [string]::IsNullOrWhiteSpace([string]$p.submittedAt)) {
                $end = String-ToDate $p.submittedAt
            }
            $elapsed = [math]::Max(0, [int](($end - (String-ToDate $p.startedAt)).TotalSeconds))
            $result += [ordered]@{
                id = $p.id
                name = $p.name
                clientIp = $p.clientIp
                lastSeenAt = $(if ($null -ne $p.PSObject.Properties["lastSeenAt"]) { [string]$p.lastSeenAt } else { "" })
                online = [bool](Test-ParticipantOnline $p)
                startedAt = $p.startedAt
                submittedAt = $p.submittedAt
                submitType = $p.submitType
                status = $p.status
                score = $p.score
                correctRate = $p.score
                totalQuestions = $p.totalQuestions
                correctCount = $p.correctCount
                wrongCount = $p.wrongCount
                answeredCount = @(As-Array $p.answers).Count
                elapsedSeconds = $elapsed
            }
        }

        Write-Json $Stream 200 @{
            ok = $true
            participants = $result
            questionStats = @(Get-QuestionStats $exam)
            scoringMode = (Get-ScoringMode $exam)
        }
        return
    }

    if ($path -match "^/api/admin/participants/(\d+)$") {
        $participantId = [int]$Matches[1]
        $p = Get-Participant $participantId
        if ($null -eq $p) {
            Write-Json $Stream 404 @{ ok = $false; message = "成员不存在" }
            return
        }

        if ($method -eq "DELETE") {
            if ($exam.status -eq "ended") {
                Write-Json $Stream 409 @{ ok = $false; message = "已结束考试的结果不能重置" }
                return
            }
            $exam.participants = @(As-Array $exam.participants | Where-Object { [int]$_.id -ne $participantId })
            Save-Data
            Write-Json $Stream 200 @{ ok = $true }
            return
        }

        if ($method -eq "GET") {
            $orderMap = @{}
            $order = As-Array $p.questionOrder
            for ($i = 0; $i -lt $order.Count; $i++) { $orderMap[[string]$order[$i]] = $i + 1 }

            $answerMap = @{}
            foreach ($a in (As-Array $p.answers)) { $answerMap[[string]$a.questionId] = $a }

            $details = @()
            foreach ($q in (As-Array $exam.activeQuestions | Sort-Object { [int]$_.position })) {
                if (-not $orderMap.ContainsKey([string]$q.id)) { continue }
                $a = $null
                if ($answerMap.ContainsKey([string]$q.id)) { $a = $answerMap[[string]$q.id] }

                $correctText = ""
                if ($q.type -eq "correction" -and -not $q.noError -and $null -ne $q.errorStart) {
                    $correctText = (Get-SafeCorrectionText $q)
                }

                $details += [ordered]@{
                    questionId = $q.id
                    position = $q.position
                    memberOrder = $orderMap[[string]$q.id]
                    type = $q.type
                    text = $q.text
                    options = @(As-Array $q.options)
                    media = @(As-Array $q.media)
                    answerText = $q.answerText
                    noError = $q.noError
                    correctText = $correctText
                    userAnswer = $(if ($null -ne $a) { $a.userAnswer } else { $null })
                    isCorrect = $(if ($null -ne $a) { $a.isCorrect } else { $null })
                    autoIsCorrect = $(if ($null -ne $a -and $null -ne $a.PSObject.Properties["autoIsCorrect"]) { $a.autoIsCorrect } elseif ($null -ne $a) { $a.isCorrect } else { $null })
                    adminOverride = $(if ($null -ne $a -and $null -ne $a.PSObject.Properties["adminOverride"]) { [bool]$a.adminOverride } else { $false })
                    reviewedAt = $(if ($null -ne $a -and $null -ne $a.PSObject.Properties["reviewedAt"]) { [string]$a.reviewedAt } else { "" })
                    reviewNote = $(if ($null -ne $a -and $null -ne $a.PSObject.Properties["reviewNote"]) { [string]$a.reviewNote } else { "" })
                    answeredAt = $(if ($null -ne $a) { $a.answeredAt } else { "" })
                }
            }

            Write-Json $Stream 200 @{ ok = $true; participant = $p; answers = $details }
            return
        }
    }

    if ($path -match "^/api/admin/participants/(\d+)/answers/(\d+)/review$" -and $method -eq "PUT") {
        $participantId = [int]$Matches[1]
        $questionId = [int]$Matches[2]
        $participant = Get-Participant $participantId

        if ($null -eq $participant) {
            Write-Json $Stream 404 @{ ok = $false; message = "成员不存在" }
            return
        }

        $restoreAuto = $false
        if ($null -ne $body -and $null -ne $body.PSObject.Properties["restoreAuto"]) {
            $restoreAuto = [bool]$body.restoreAuto
        }

        $desiredCorrect = $false
        if ($null -ne $body -and $null -ne $body.PSObject.Properties["isCorrect"]) {
            $desiredCorrect = [bool]$body.isCorrect
        }

        $note = ""
        if ($null -ne $body -and $null -ne $body.PSObject.Properties["note"]) {
            $note = [string]$body.note
        }

        $reviewed = Apply-AnswerReview -Participant $participant -QuestionId $questionId -IsCorrect $desiredCorrect -RestoreAuto $restoreAuto -Note $note
        if ($null -eq $reviewed) {
            Write-Json $Stream 404 @{ ok = $false; message = "该成员尚未作答这道题，无法人工改判" }
            return
        }

        Save-Data
        if ($exam.status -eq "ended") {
            Save-HistoryExam $exam
        }

        Write-Json $Stream 200 @{
            ok = $true
            participant = $participant
            answer = $reviewed
        }
        return
    }

    if ($path -match "^/api/admin/participants/(\d+)/collect$" -and $method -eq "POST") {
        $participantId = [int]$Matches[1]
        $participant = Get-Participant $participantId

        if ($null -eq $participant) {
            Write-Json $Stream 404 @{ ok = $false; message = "成员不存在" }
            return
        }

        if ($participant.status -eq "submitted") {
            Write-Json $Stream 409 @{ ok = $false; message = "该成员已经交卷" }
            return
        }

        # Collecting one participant must not affect anyone else.
        # Unanswered questions remain unanswered and are counted in wrong/unanswered stats.
        Recalculate-Participant $participant
        $participant.status = "submitted"
        $participant.submittedAt = Date-ToString (Get-Date)
        $participant.submitType = "admin_collect"
        Set-ObjectProperty $participant "lastSeenAt" (Date-ToString (Get-Date))

        Save-Data

        Write-Json $Stream 200 @{
            ok = $true
            participant = $participant
            state = (Get-PublicState $participant)
        }
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/admin/history") {
        Write-Json $Stream 200 @{ ok = $true; history = @(Get-HistoryList) }
        return
    }

    if ($path -match "^/api/admin/history/([A-Za-z0-9_-]+)/participants/(\d+)/answers/(\d+)/review$" -and $method -eq "PUT") {
        $historyExamId = $Matches[1]
        $participantId = [int]$Matches[2]
        $questionId = [int]$Matches[3]

        $historyExam = Load-HistoryExam $historyExamId
        if ($null -eq $historyExam) {
            Write-Json $Stream 404 @{ ok = $false; message = "历史考试不存在" }
            return
        }

        $participant = As-Array $historyExam.participants |
            Where-Object { [int]$_.id -eq $participantId } |
            Select-Object -First 1

        if ($null -eq $participant) {
            Write-Json $Stream 404 @{ ok = $false; message = "成员不存在" }
            return
        }

        $restoreAuto = $false
        if ($null -ne $body -and $null -ne $body.PSObject.Properties["restoreAuto"]) {
            $restoreAuto = [bool]$body.restoreAuto
        }

        $desiredCorrect = $false
        if ($null -ne $body -and $null -ne $body.PSObject.Properties["isCorrect"]) {
            $desiredCorrect = [bool]$body.isCorrect
        }

        $note = ""
        if ($null -ne $body -and $null -ne $body.PSObject.Properties["note"]) {
            $note = [string]$body.note
        }

        $reviewed = Apply-AnswerReview -Participant $participant -QuestionId $questionId -IsCorrect $desiredCorrect -RestoreAuto $restoreAuto -Note $note
        if ($null -eq $reviewed) {
            Write-Json $Stream 404 @{ ok = $false; message = "该成员尚未作答这道题，无法人工改判" }
            return
        }

        Save-HistoryExam $historyExam

        $current = Current-Exam
        if ([string]$current.id -eq [string]$historyExam.id) {
            $script:Data.currentExam = Deep-Clone $historyExam
            Save-Data
        }

        Write-Json $Stream 200 @{
            ok = $true
            participant = $participant
            answer = $reviewed
            summary = (Get-ExamSummary $historyExam)
            questionStats = @(Get-QuestionStats $historyExam)
        }
        return
    }

    if ($path -match "^/api/admin/history/([A-Za-z0-9_-]+)/retest$" -and $method -eq "POST") {
        $historyExam = Load-HistoryExam $Matches[1]
        if ($null -eq $historyExam) {
            Write-Json $Stream 404 @{ ok = $false; message = "历史考试不存在" }
            return
        }

        $current = Current-Exam
        if ($current.status -eq "running") {
            Write-Json $Stream 409 @{ ok = $false; message = "当前有考试正在进行，不能创建重新测验" }
            return
        }

        $sourceQuestions = @()
        if (@(As-Array $historyExam.activeQuestions).Count -gt 0) {
            $sourceQuestions = @(As-Array $historyExam.activeQuestions)
        }
        else {
            $sourceQuestions = @(As-Array $historyExam.questions)
        }

        if ($sourceQuestions.Count -eq 0) {
            Write-Json $Stream 409 @{ ok = $false; message = "该历史考试没有可复制的题目" }
            return
        }

        $retestParams = @{
            Name = ([string]$historyExam.name + "（重新测验）")
            DurationMinutes = [int]$historyExam.durationMinutes
            PassScore = [double]$historyExam.passScore
            AccessCode = [string]$historyExam.accessCode
            RandomizeQuestions = [bool]$historyExam.randomizeQuestions
            ScoringMode = (Get-ScoringMode $historyExam)
        }

        $newExam = New-DraftExam @retestParams
        $newExam.questions = @(Deep-Clone $sourceQuestions)
        $newExam.activeQuestions = @()
        $newExam.participants = @()

        $script:Data.currentExam = $newExam
        Save-Data

        Write-Json $Stream 200 @{
            ok = $true
            exam = $newExam
            sourceExamId = $historyExam.id
        }
        return
    }

    if ($path -match "^/api/admin/history/([A-Za-z0-9_-]+)/export\.xlsx$" -and $method -eq "GET") {
        $historyExam = Load-HistoryExam $Matches[1]
        if ($null -eq $historyExam) {
            Write-Json $Stream 404 @{ ok = $false; message = "历史考试不存在" }
            return
        }

        try {
            $bytes = Build-XlsxBytes $historyExam
            Write-Response $Stream 200 "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" $bytes @{
                "Content-Disposition" = "attachment; filename=exam_$($historyExam.id)_results.xlsx"
            }
        }
        catch {
            Write-Json $Stream 500 @{ ok = $false; message = "Excel 导出失败"; detail = $_.Exception.Message }
        }
        return
    }

    if ($path -match "^/api/admin/history/([A-Za-z0-9_-]+)$" -and $method -eq "GET") {
        $historyExam = Load-HistoryExam $Matches[1]
        if ($null -eq $historyExam) {
            Write-Json $Stream 404 @{ ok = $false; message = "历史考试不存在" }
            return
        }
        Write-Json $Stream 200 @{
            ok = $true
            exam = $historyExam
            summary = (Get-ExamSummary $historyExam)
            questionStats = @(Get-QuestionStats $historyExam)
        }
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/public") {
        $questionCount = 0
        if ($exam.status -eq "draft") { $questionCount = @(As-Array $exam.questions).Count }
        else { $questionCount = @(As-Array $exam.activeQuestions).Count }

        Write-Json $Stream 200 @{
            ok = $true
            exam = @{
                id = $exam.id
                name = $exam.name
                status = $exam.status
                durationMinutes = $exam.durationMinutes
                questionCount = $questionCount
                scoringMode = (Get-ScoringMode $exam)
            }
        }
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/exam/start") {
        if ($exam.status -ne "running") {
            $msg = $(if ($exam.status -eq "draft") { "考试尚未开始，请等待管理员开始考试" } else { "本场考试已经结束" })
            Write-Json $Stream 403 @{ ok = $false; message = $msg }
            return
        }

        if ($null -eq $body) {
            Write-Json $Stream 400 @{ ok = $false; message = "参数错误" }
            return
        }

        $name = ([string]$body.name).Trim()
        $code = ([string]$body.accessCode).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Json $Stream 400 @{ ok = $false; message = "请输入姓名" }
            return
        }
        if ($code -ne [string]$exam.accessCode) {
            Write-Json $Stream 403 @{ ok = $false; message = "考试口令错误" }
            return
        }

        $existing = As-Array $exam.participants | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if ($null -ne $existing) {
            Write-Json $Stream 409 @{ ok = $false; message = "该姓名已经参加过本场考试，请联系管理员" }
            return
        }

        # Keep question types grouped for every member:
        # 1) correction/judgement questions first
        # 2) choice questions
        # 3) subjective questions
        # When randomization is enabled, shuffle only inside each type group.
        $orderedQuestions = @(As-Array $exam.activeQuestions | Sort-Object { [int]$_.position })

        $correctionIds = @(
            $orderedQuestions |
                Where-Object { [string]$_.type -eq "correction" } |
                ForEach-Object { [int]$_.id }
        )

        $subjectiveIds = @(
            $orderedQuestions |
                Where-Object { [string]$_.type -eq "subjective" } |
                ForEach-Object { [int]$_.id }
        )

        if ([bool]$exam.randomizeQuestions) {
            $correctionIds = @(Shuffle-Ids $correctionIds)
            $subjectiveIds = @(Shuffle-Ids $subjectiveIds)
        }

        $choiceIds = @($orderedQuestions | Where-Object { $_.type -in @('single','multiple') } | ForEach-Object { [int]$_.id })
        if ([bool]$exam.randomizeQuestions) { $choiceIds = @(Shuffle-Ids $choiceIds) }
        $ids = @($correctionIds) + @($choiceIds) + @($subjectiveIds)

        $script:Data.counters.participant = [int]$script:Data.counters.participant + 1
        $started = Get-Date
        $token = New-Token

        $p = [ordered]@{
            id = [int]$script:Data.counters.participant
            examToken = $token
            name = $name
            clientIp = $ClientIp
            lastSeenAt = (Date-ToString $started)
            startedAt = (Date-ToString $started)
            expiresAt = (Date-ToString ($started.AddMinutes([int]$exam.durationMinutes)))
            submittedAt = ""
            submitType = ""
            status = "in_progress"
            score = 0
            totalQuestions = $ids.Count
            correctCount = 0
            wrongCount = 0
            questionOrder = $ids
            answers = @()
        }

        $exam.participants = @(As-Array $exam.participants) + @($p)
        Save-Data

        Write-Json $Stream 200 @{ ok = $true; token = $token; state = (Get-PublicState $p) }
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/exam/heartbeat") {
        $token = Get-HeaderValue $Request.headers "X-Exam-Token"
        $participant = Get-ParticipantByToken $token

        if ($null -eq $participant) {
            Write-Json $Stream 200 @{ ok = $true; currentExam = $false }
            return
        }

        Set-ObjectProperty $participant "lastSeenAt" (Date-ToString (Get-Date))
        $participant = Ensure-Timeout $participant
        $publicState = Get-PublicState $participant

        Write-Json $Stream 200 @{
            ok = $true
            currentExam = $true
            examId = $exam.id
            participantStatus = $participant.status
            state = $publicState
        }
        return
    }

    if ($method -eq "GET" -and $path -eq "/api/exam/state") {
        $token = Get-HeaderValue $Request.headers "X-Exam-Token"
        $p = Get-ParticipantByToken $token
        if ($null -ne $p) {
            Write-Json $Stream 200 @{ ok = $true; state = (Get-PublicState $p) }
            return
        }

        $historical = Find-HistoryParticipantByToken $token
        if ($null -ne $historical) {
            Write-Json $Stream 200 @{ ok = $true; state = (Get-HistoryResultState $historical.exam $historical.participant) }
            return
        }

        Write-Json $Stream 401 @{ ok = $false; message = "未找到考试记录" }
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/exam/answer") {
        $token = Get-HeaderValue $Request.headers "X-Exam-Token"
        $p = Get-ParticipantByToken $token
        if ($null -eq $p) {
            $historical = Find-HistoryParticipantByToken $token
            if ($null -ne $historical) {
                Write-Json $Stream 409 @{ ok = $false; message = "考试已经结束"; state = (Get-HistoryResultState $historical.exam $historical.participant) }
                return
            }
            Write-Json $Stream 401 @{ ok = $false; message = "未找到考试记录" }
            return
        }

        if ($exam.status -ne "running") {
            Write-Json $Stream 409 @{ ok = $false; message = "考试已经结束"; state = (Get-PublicState $p) }
            return
        }

        $p = Ensure-Timeout $p
        if ($p.status -ne "in_progress") {
            Write-Json $Stream 409 @{ ok = $false; message = "考试已结束"; state = (Get-PublicState $p) }
            return
        }

        $answeredIds = @{}
        foreach ($a in (As-Array $p.answers)) { $answeredIds[[string]$a.questionId] = $true }
        $currentQid = $null
        foreach ($qid in (As-Array $p.questionOrder)) {
            if (-not $answeredIds.ContainsKey([string]$qid)) { $currentQid = [int]$qid; break }
        }

        if ($null -eq $currentQid) {
            Submit-Participant $p "completed"
            Write-Json $Stream 200 @{ ok = $true; completed = $true; state = (Get-PublicState $p) }
            return
        }

        if ([int]$body.questionId -ne $currentQid) {
            Write-Json $Stream 409 @{ ok = $false; message = "请按当前题目作答" }
            return
        }

        $q = Get-ActiveQuestion $currentQid
        if ($null -eq $q) {
            Write-Json $Stream 404 @{ ok = $false; message = "题目不存在" }
            return
        }

        $isCorrect = $false
        $userAnswer = ""

        if ($q.type -in @('single','multiple')) {
            $keys = @(([string]$body.answer).Split(','))
            $valid = $true
            foreach ($key in $keys) { if ($key -notmatch '^[A-H]$' -or ([int][char]$key - 65) -ge @(As-Array $q.options).Count) { $valid = $false } }
            if (-not $valid -or ($keys | Select-Object -Unique).Count -ne $keys.Count -or ($q.type -eq 'single' -and $keys.Count -ne 1)) {
                Write-Json $Stream 400 @{ ok = $false; message = '请选择有效的选项，单选题只能选择一项' }; return
            }
            $userAnswer = ($keys | Sort-Object) -join ','
            $isCorrect = $userAnswer -ceq ((([string]$q.answerText).Split(',') | Sort-Object) -join ',')
        }
        elseif ($q.type -eq "subjective") {
            $userAnswer = [string]$body.answer
            $isCorrect = (Normalize-Subjective $userAnswer) -ceq (Normalize-Subjective ([string]$q.answerText))
        }
        else {
            if ([bool]$q.noError) {
                if ([bool]$body.noError) {
                    $userAnswer = "本题无错误"
                    $isCorrect = $true
                }
                else {
                    $userAnswer = [string]$body.charIndex
                    $isCorrect = $false
                }
            }
            else {
                if ([bool]$body.noError) {
                    $userAnswer = "本题无错误"
                    $isCorrect = $false
                }
                else {
                    if ($null -eq $body.charIndex) {
                        Write-Json $Stream 400 @{ ok = $false; message = "请选择【本题正确】或点击你认为错误的文字" }
                        return
                    }
                    $index = [int]$body.charIndex
                    $userAnswer = [string]$index
                    $isCorrect = ($index -ge [int]$q.errorStart -and $index -lt [int]$q.errorEnd)
                }
            }
        }

        $answerRecord = [ordered]@{
            questionId = $q.id
            userAnswer = $userAnswer
            isCorrect = [bool]$isCorrect
            autoIsCorrect = [bool]$isCorrect
            adminOverride = $false
            reviewedAt = ""
            reviewNote = ""
            answeredAt = (Date-ToString (Get-Date))
        }

        $p.answers = @(As-Array $p.answers) + @($answerRecord)
        Recalculate-Participant $p

        # Only finish the exam when every question has actually been answered.
        # A wrong answer is still a completed answer for that question, but it must
        # never terminate the whole exam unless it was the final unanswered question.
        $answeredQuestionIds = @{}
        foreach ($savedAnswer in (As-Array $p.answers)) {
            $answeredQuestionIds[[string]$savedAnswer.questionId] = $true
        }

        $allAnswered = $true
        foreach ($orderedQuestionId in (As-Array $p.questionOrder)) {
            if (-not $answeredQuestionIds.ContainsKey([string]$orderedQuestionId)) {
                $allAnswered = $false
                break
            }
        }

        $completed = $allAnswered

        if ($completed) {
            Submit-Participant $p "completed"
        }
        else {
            Save-Data
        }

        $answerReveal = $null
        if (-not [bool]$isCorrect) {
            $answerReveal = Get-AnswerReveal $q
        }

        Write-Json $Stream 200 @{
            ok = $true
            correct = [bool]$isCorrect
            completed = [bool]$completed
            state = (Get-PublicState $p)
            answerReveal = $answerReveal
        }
        return
    }

    if ($method -eq "POST" -and $path -eq "/api/exam/submit") {
        $token = Get-HeaderValue $Request.headers "X-Exam-Token"
        $p = Get-ParticipantByToken $token
        if ($null -eq $p) {
            $historical = Find-HistoryParticipantByToken $token
            if ($null -ne $historical) {
                Write-Json $Stream 200 @{ ok = $true; state = (Get-HistoryResultState $historical.exam $historical.participant) }
                return
            }
            Write-Json $Stream 401 @{ ok = $false; message = "未找到考试记录" }
            return
        }

        $p = Ensure-Timeout $p
        if ($p.status -eq "in_progress") {
            $submitType = "manual"
            if ($null -ne $body -and [string]$body.submitType -eq "timeout") { $submitType = "timeout" }
            Submit-Participant $p $submitType
        }

        Write-Json $Stream 200 @{ ok = $true; state = (Get-PublicState $p) }
        return
    }

    Write-Json $Stream 404 @{ ok = $false; message = "接口不存在" }
}



function Ensure-LanFirewallRule {
    param([int]$ListenPort)

    $ruleName = "LAN Exam System $ListenPort"

    try {
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Write-Host "LAN firewall access is ready." -ForegroundColor Green
            return $true
        }
    }
    catch {
        # Ignore and fall through to elevated setup.
    }

    Write-Host ""
    Write-Host "First run: Windows will ask for administrator permission once." -ForegroundColor Yellow
    Write-Host "This only opens TCP port $ListenPort for devices on the local network." -ForegroundColor Gray
    Write-Host ""

    # Use netsh in one non-interactive elevated command.
    # This avoids PowerShell parameter binding / multiline continuation issues.
    $netshCommand = "netsh advfirewall firewall delete rule name=""$ruleName"" >nul 2>&1 & " +
                    "netsh advfirewall firewall add rule name=""$ruleName"" dir=in action=allow protocol=TCP localport=$ListenPort profile=private,public remoteip=localsubnet"

    try {
        $args = @("/d", "/s", "/c", $netshCommand)
        $proc = Start-Process -FilePath "cmd.exe" -Verb RunAs -ArgumentList $args -WindowStyle Hidden -Wait -PassThru

        if ($proc.ExitCode -eq 0) {
            Write-Host "LAN firewall access has been configured automatically." -ForegroundColor Green
            return $true
        }

        Write-Host "Firewall configuration was not completed." -ForegroundColor Yellow
        Write-Host "The server will still start, but other LAN computers may not be able to connect." -ForegroundColor Yellow
        return $false
    }
    catch {
        Write-Host "Firewall configuration was skipped or cancelled." -ForegroundColor Yellow
        Write-Host "The server will still start." -ForegroundColor Yellow
        return $false
    }
}

$listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Any, $Port)

try {
    $listener.Start()
}
catch {
    Write-Host ""
    Write-Host "Unable to start LAN Exam System on port $Port." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    throw
}

$lanIp = Get-LanIPv4
$adminUrl = "http://$lanIp`:$Port/admin"
$userUrl = "http://$lanIp`:$Port/"

Clear-Host
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                 LAN Exam System v0.1.0" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Admin:   $adminUrl" -ForegroundColor Yellow
Write-Host "Members: $userUrl" -ForegroundColor Yellow
Write-Host ""
Write-Host "Default admin: admin / admin123" -ForegroundColor Gray
Write-Host "Close this window to stop the server." -ForegroundColor Gray
Write-Host "============================================================" -ForegroundColor Cyan

try { Start-Process "http://localhost:$Port/admin" } catch { }

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 10000
        $client.SendTimeout = 10000
        $stream = $client.GetStream()
        $request = Read-HttpRequest $stream
        if ($null -ne $request) {
            $clientIp = $client.Client.RemoteEndPoint.Address.ToString()
            Handle-Request $request $stream $clientIp
        }
    }
    catch {
        if ($null -ne $client) {
            try {
                Write-Json $client.GetStream() 500 @{ ok = $false; message = "服务器内部错误"; detail = $_.Exception.Message }
            }
            catch { }
        }
        Write-Host "Request error: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if ($null -ne $client) {
            try { $client.Close() } catch { }
        }
    }
}
