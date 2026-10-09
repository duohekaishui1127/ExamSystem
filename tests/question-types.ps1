$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) ('exam-types-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp | Out-Null
try {
    $source = [IO.File]::ReadAllText((Join-Path $root 'server.ps1'))
    $source = $source.Substring(0, $source.IndexOf('$listener = New-Object'))
    $copy = Join-Path $temp 'server.ps1'
    [IO.File]::WriteAllText($copy, $source, (New-Object Text.UTF8Encoding($true)))
    . $copy
    function Write-Json { param($Stream,$Status,$Value) $script:response = $Value; $script:status = $Status }
    function Assert($condition,$message) { if (-not $condition) { throw $message } }
    function Call($method,$path,$payload,$headers=@{}) {
        $script:response=$null
        Handle-Request @{method=$method;path=$path;body=($payload|ConvertTo-Json -Depth 40);headers=$headers} $null '127.0.0.1'
        if ($script:status -ge 400) { throw "HTTP $script:status $($script:response.message)" }
        return $script:response
    }
    $login=Call POST '/api/admin/login' @{username='admin';password='admin123'}
    $admin=@{'X-Admin-Token'=$login.token}
    $image=@{name='question.png';data='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='}
    $attachment=@{name='material.txt';data='data:application/octet-stream;base64,aGVsbG8='}
    $single=@{type='single';text='';options=@('One','Two','Three','Four');answerText='B';media=@($image,$attachment)}
    $one=Call POST '/api/admin/questions' $single $admin
    $multi=@{type='multiple';text='Select two';options=@('One','Two','Three','Four');answerText='A,C';media=@()}
    $two=Call POST '/api/admin/questions' $multi $admin
    $subjective=@{type='subjective';text='';answerText='hello';media=@($image)}
    $three=Call POST '/api/admin/questions' $subjective $admin
    $four=Call POST '/api/admin/questions' @{type='correction';text='True statement';noError=$true} $admin
    # Exercise editing a question restored from JSON, as happens after restart.
    $script:Data = $script:Data | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $null=Call PUT "/api/admin/questions/$($one.id)" $single $admin
    $questions=(Call GET '/api/admin/questions' @{} $admin).questions
    Assert ($questions.Count -eq 4) 'Question count'
    Assert ($questions[0].media.Count -eq 2) 'Media persisted'
    $single.media=$questions[0].media
    $null=Call PUT "/api/admin/questions/$($one.id)" $single $admin
    function Write-Response { param($Stream,$Status,$ContentType,$BodyBytes,$ExtraHeaders) $script:fileResponse=@{status=$Status;mime=$ContentType;bytes=$BodyBytes;headers=$ExtraHeaders} }
    Handle-Request @{method='GET';path=$single.media[0].data;body='';headers=@{}} $null '127.0.0.1'
    Assert ($script:fileResponse.mime -eq 'image/png' -and $script:fileResponse.bytes.Length -gt 0) 'Image serving'
    Handle-Request @{method='GET';path=$single.media[1].data;body='';headers=@{}} $null '127.0.0.1'
    Assert ($script:fileResponse.headers['Content-Disposition'] -eq 'attachment') 'Attachment download'

    foreach ($bad in @(
        @{type='single';text='Too few';options=@('A','B','C');answerText='A'},
        @{type='multiple';text='Too many';options=@('A','B','C','D','E');answerText='A,B'},
        @{type='single';text='Empty option';options=@('A','B','C','');answerText='A'},
        @{type='single';text='Invalid';options=@('A','B','C','D');answerText='A,B'},
        @{type='multiple';text='Invalid';options=@('A','B','C','D');answerText='A'},
        @{type='single';text='Invalid';options=@('A','B','C','D');answerText='H'},
        @{type='correction';text='Invalid';noError=$true;media=@($image)},
        @{type='subjective';text='';answerText='x'},
        @{type='unknown';text='Invalid'}
    )) {
        $rejected=$false
        try { $null=Call POST '/api/admin/questions' $bad $admin } catch { $rejected=$true }
        Assert $rejected 'Invalid question must be rejected'
        $rejected=$false
        try { $null=Call PUT "/api/admin/questions/$($one.id)" $bad $admin } catch { $rejected=$true }
        Assert $rejected 'Invalid edit must be rejected'
    }
    $null=Call POST '/api/admin/exam/start' @{} $admin
    foreach ($scenario in @(@{name='correct';answer='C,A';expected=$true},@{name='missing';answer='A';expected=$false},@{name='extra';answer='A,B,C';expected=$false},@{name='wrong';answer='B,C';expected=$false})) {
        $entry=Call POST '/api/exam/start' @{name=$scenario.name;accessCode='123456'}
        $member=@{'X-Exam-Token'=$entry.token}
        $state=$entry.state
        Assert ($state.totalQuestions -eq 4) 'All question types must be assigned'
        for($i=0;$i -lt 4;$i++) {
            $q=$state.question
            Assert ($null -eq $q.answerText) 'Public question leaked correct answer'
            $payload=@{questionId=$q.id}
            switch($q.type) {
                single { $payload.answer='B'; Assert ($q.media.Count -eq 2 -and $q.options.Count -eq 4) 'Public media/options missing' }
                multiple { $payload.answer=$scenario.answer }
                subjective { $payload.answer='HELLO!' }
                correction { $payload.noError=$true }
                default { throw 'Unexpected question type' }
            }
            $result=Call POST '/api/exam/answer' $payload $member
            if($q.type -eq 'multiple') { Assert ($result.correct -eq $scenario.expected) 'Multi-select grading'; if(-not $scenario.expected){Assert ($result.answerReveal.answerText -eq 'A,C') 'Correct answer reveal'} }
            else { Assert $result.correct 'Existing/single grading regression' }
            $state=$result.state
        }
        Assert ($state.status -eq 'submitted') 'Exam should complete'
    }
    $null=Call POST '/api/admin/exam/end' @{} $admin
    Assert (@(Get-ChildItem (Join-Path $temp 'data/history') -Filter '*.json').Count -gt 0) 'History archive missing'
    $history = Current-Exam
    $xlsx = Build-XlsxBytes $history
    Assert ($xlsx.Length -gt 100) 'Excel export'
    $null=Call POST "/api/admin/history/$($history.id)/retest" @{} $admin
    $retest=Current-Exam
    Assert ($retest.questions.Count -eq 4) 'Retest question count'
    $copied = @($retest.questions | Where-Object { $_.type -eq 'single' })[0]
    Assert ($copied.media[0].data -eq $single.media[0].data) 'Retest media references'
    Write-Output 'PASS: create/edit, validation, image-only questions, public payload, all question types, multi-select grading, completion, history, downloads, Excel export, retest.'
} finally { Remove-Item -Recurse -Force $temp }
