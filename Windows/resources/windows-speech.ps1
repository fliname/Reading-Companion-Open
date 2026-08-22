param([string]$Language = "zh-CN")

Add-Type -AssemblyName System.Speech
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$culture = [System.Globalization.CultureInfo]::GetCultureInfo($Language)
try {
    $recognizer = New-Object System.Speech.Recognition.SpeechRecognitionEngine($culture)
} catch {
    $recognizer = New-Object System.Speech.Recognition.SpeechRecognitionEngine
}
$recognizer.SetInputToDefaultAudioDevice()
$recognizer.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
$recognizer.add_SpeechRecognized({
    param($sender, $eventArgs)
    if ($eventArgs.Result.Text) {
        $payload = @{ text = $eventArgs.Result.Text; final = $true; confidence = $eventArgs.Result.Confidence } | ConvertTo-Json -Compress
        [Console]::Out.WriteLine($payload)
        [Console]::Out.Flush()
    }
})
$recognizer.RecognizeAsync([System.Speech.Recognition.RecognizeMode]::Multiple)
while ($true) { Start-Sleep -Milliseconds 200 }
