$m3uFile = "C:\playlist\main.m3u"
$outputFile = "C:\playlist\main_output.m3u"

$lines = Get-Content -Path $m3uFile -Encoding UTF8

$blocks = @()
$currentGroupComments = @()
$i = 0
while ($i -lt $lines.Count) {
    $line = $lines[$i]
    if ($line -match '^#EXTINF') {
        $extinf = $line; $i++
        while ($i -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$i])) { $i++ }
        if ($i -lt $lines.Count -and $lines[$i] -notmatch '^#') {
            $blocks += @{ GroupComments = @($currentGroupComments); Extinf = $extinf; Url = $lines[$i].Trim(); Name = ($extinf -split ',')[-1].Trim() }
        }
        $i++
    } elseif ($line -match '^#EXTM3U') { $i++ }
    elseif ([string]::IsNullOrWhiteSpace($line)) { $i++ }
    elseif ($line -match '^#') { $currentGroupComments = @($line); $i++ }
    else { $currentGroupComments = @(); $i++ }
}

$total = $blocks.Count
Write-Host "Found $total channel entries to test"
$total | Write-Host

$scriptBlock = {
    param($url)
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    try {
        $h = New-Object System.Net.Http.HttpClientHandler
        $h.AllowAutoRedirect = $true; $h.MaxAutomaticRedirections = 5
        $c = New-Object System.Net.Http.HttpClient($h)
        $c.Timeout = [TimeSpan]::FromSeconds(8)
        $c.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        $c.DefaultRequestHeaders.Accept.ParseAdd("*/*")
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $url)
        $req.Headers.Add("Range", "bytes=0-0")
        $res = $c.SendAsync($req).GetAwaiter().GetResult()
        $sc = [int]$res.StatusCode
        $res.Dispose(); $req.Dispose(); $c.Dispose(); $h.Dispose()
        return @{ Working = ($sc -ge 200 -and $sc -lt 400); Status = $sc }
    } catch {
        try {
            $c2 = New-Object System.Net.Http.HttpClient
            $c2.Timeout = [TimeSpan]::FromSeconds(8)
            $c2.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            $r2 = $c2.GetAsync($url).GetAwaiter().GetResult()
            $sc2 = [int]$r2.StatusCode
            $r2.Dispose(); $c2.Dispose()
            return @{ Working = ($sc2 -ge 200 -and $sc2 -lt 400); Status = $sc2 }
        } catch { return @{ Working = $false; Status = -1 } }
    }
}

$pool = [RunspaceFactory]::CreateRunspacePool(1, 25)
$pool.Open()

$handles = @()
foreach ($block in $blocks) {
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($scriptBlock).AddArgument($block.Url)
    $handle = $ps.BeginInvoke()
    $handles += @{ PS = $ps; Handle = $handle; Block = $block }
}

$workingBlocks = @()
$completed = 0
foreach ($jh in $handles) {
    try {
        $result = $jh.PS.EndInvoke($jh.Handle)
        $completed++
        $block = $jh.Block
        if ($result -and $result.Count -gt 0 -and $result[0].Working) {
            Write-Host "[$completed/$total] OK ($($result[0].Status)) - $($block.Name)"
            $workingBlocks += $block
        } else {
            $s = if ($result -and $result.Count -gt 0) { $result[0].Status } else { "?" }
            Write-Host "[$completed/$total] FAIL ($s) - $($block.Name)"
        }
    } catch {
        Write-Host "Error collecting result: $_"
    } finally {
        $jh.PS.Dispose()
    }
    Write-Progress -Activity "Testing channels" -Status "$completed/$total" -PercentComplete (($completed/$total)*100)
}

$pool.Close(); $pool.Dispose()

$workingCount = $workingBlocks.Count
Write-Host "`n=== Working: $workingCount/$total ==="

$outputLines = @()
$outputLines += "#EXTM3U"; $outputLines += ""
$prevGroup = ""
foreach ($block in $workingBlocks) {
    $gk = if ($block.GroupComments.Count -gt 0) { $block.GroupComments[0] } else { "" }
    if ($block.GroupComments.Count -gt 0 -and $gk -ne $prevGroup) {
        if ($outputLines.Count -gt 2) { $outputLines += "" }
        foreach ($c in $block.GroupComments) { $outputLines += $c }
        $prevGroup = $gk
    }
    $outputLines += $block.Extinf; $outputLines += $block.Url
}
$outputLines += ""
$outputLines | Set-Content -Path $outputFile -Encoding UTF8

if ($workingCount -gt 0) {
    Copy-Item -Path $outputFile -Destination $m3uFile -Force
    Write-Host "Copied $workingCount working channels to main.m3u"
}
