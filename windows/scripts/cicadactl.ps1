param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Command)
$pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", "cicada-dev", [System.IO.Pipes.PipeDirection]::InOut)
$pipe.Connect(3000)
$writer = New-Object System.IO.StreamWriter($pipe); $writer.AutoFlush = $true
$reader = New-Object System.IO.StreamReader($pipe)
$writer.WriteLine(($Command -join " "))
$reader.ReadLine()
$pipe.Dispose()
