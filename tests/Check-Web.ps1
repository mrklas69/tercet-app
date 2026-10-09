param([switch]$KeepArtifacts)
# Kontrola mobilní čtečky web/tercet.html (čtení fronty). Samostatná sada:
# nepotřebuje build ani Tercet.dll, čte zdrojové texty a spouští headless Edge
# proti vlastnímu falešnému serveru na 127.0.0.1. Provozní frontu ani server
# na example.com nepoužívá; demodata bere z tests/queue-fixture.json.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
function Assert($condition, $message) { if (-not $condition) { throw $message } }

# --- 1. Parita palety a popisků se zdrojem desktopu -------------------------
# Jediný zdroj barev, popisků a period je QueueAttention.cs; stránka je musí
# opakovat (nemá přístup k .NET), proto se porovnává text obou souborů.
$attentionSource = Get-Content (Join-Path $repo 'src/Tercet/QueueAttention.cs') -Raw -Encoding utf8
$viewSource = Get-Content (Join-Path $repo 'src/Tercet/QueueView.xaml.cs') -Raw -Encoding utf8
$pagePath = Join-Path $repo 'web/tercet.html'
$page = Get-Content $pagePath -Raw -Encoding utf8

$desktop = @{}
foreach ($match in [regex]::Matches($attentionSource, '"(\w+)" => \("(#[0-9A-Fa-f]{6})", "([^"]+)", \d+, (\d+)\)')) {
    $desktop[$match.Groups[1].Value] = @($match.Groups[2].Value.ToUpperInvariant(), $match.Groups[3].Value, [int]$match.Groups[4].Value)
}
Assert ($desktop.Count -eq 5) "Desktop palette: expected 5 situations, parsed $($desktop.Count)"
$webBlock = [regex]::Match($page, 'const situations = \{(.*?)\};', 'Singleline').Groups[1].Value
$web = @{}
foreach ($match in [regex]::Matches($webBlock, '(\w+): \["(#[0-9A-Fa-f]{6})", "([^"]+)", (\d+)\]')) {
    $web[$match.Groups[1].Value] = @($match.Groups[2].Value.ToUpperInvariant(), $match.Groups[3].Value, [int]$match.Groups[4].Value)
}
Assert ($web.Count -eq $desktop.Count) "Web palette: expected $($desktop.Count) situations, parsed $($web.Count)"
foreach ($situation in $desktop.Keys) {
    Assert $web.ContainsKey($situation) "Web palette lacks situation $situation"
    for ($i = 0; $i -lt 3; $i++) {
        Assert ($web[$situation][$i] -eq $desktop[$situation][$i]) "Palette mismatch for ${situation}: web '$($web[$situation][$i])' vs desktop '$($desktop[$situation][$i])'"
    }
}
# Popisky perspektiv (QueueView.PerspectiveLabel) a poměry míchání odstínů
# blikající diody (35 % k bílé, 50 % k černé) musí sedět také.
foreach ($pair in @(@('minutes', 'min'), @('hours', 'hr'), @('days', 'day'))) {
    Assert ($viewSource -match ('"{0}" => "{1}"' -f $pair)) "Desktop perspective label missing: $($pair -join ' => ')"
    Assert ($page -match ('{0}: "{1}"' -f $pair)) "Web perspective label missing: $($pair -join ': ')"
}
Assert ($viewSource.Contains('Mix(color.Color, Colors.White, 0.35)') -and $page.Contains('mix(color, white, 0.35)')) 'Bright tone ratio differs'
Assert ($viewSource.Contains('Mix(color.Color, Colors.Black, 0.5)') -and $page.Contains('mix(color, black, 0.5)')) 'Dim tone ratio differs'
'PASS: palette, labels and blink periods match QueueAttention and QueueView'

# --- 2. Falešný server a headless Edge ---------------------------------------
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
Assert (Test-Path $edge) "Edge not found: $edge"
$demoBytes = [IO.File]::ReadAllBytes((Join-Path $repo 'tests/queue-fixture.json'))
$demo = [Text.Encoding]::UTF8.GetString($demoBytes) | ConvertFrom-Json
# Očekávané počty z demodat: průchod rodič před potomky jako QueueDocument.Rows().
$rows = [Collections.Generic.List[object]]::new()
function Walk($items, $depth) { foreach ($item in $items) { $rows.Add(@{ Kind = $item.kind; Situation = $item.situation; Depth = $depth }); if ($item.children) { Walk $item.children ($depth + 1) } } }
Walk $demo.queue 0
$tasks = @($rows | Where-Object { $_.Kind -ne 'group' })
$blinking = @($tasks | Where-Object { $desktop[$_.Situation][2] -gt 0 })
Assert ($tasks.Count -gt 0 -and $blinking.Count -gt 0 -and $blinking.Count -lt $tasks.Count) 'Demo data must contain blinking and static tasks'

# Tokeny mají tvar serveru (32 hex); každý scénář má vlastní.
$demoToken = '0123456789abcdef0123456789abcdef'
$unknownToken = 'ffffffffffffffffffffffffffffffff'
$schemaToken = '11111111111111111111111111111111'
$failToken = '22222222222222222222222222222222'
# ETag serveru je prvních 32 hex znaků SHA-256 obsahu (podle protokolu).
$sha = [Security.Cryptography.SHA256]::HashData($demoBytes)
$etag = '"' + (($sha | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 32) + '"'
$lastModified = [DateTimeOffset]::new(2026, 9, 26, 10, 0, 0, [TimeSpan]::Zero)

$testDir = Join-Path ([IO.Path]::GetTempPath()) ('Tercet-web-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($testDir) | Out-Null
$pageBytes = [IO.File]::ReadAllBytes($pagePath)
# Volný port: TcpListener na portu 0 ho přidělí, hned se uvolní pro HttpListener.
$probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()
$requests = [Collections.Generic.List[object]]::new()

function Send($response, [int]$status, [string]$type, [byte[]]$body) {
    $response.StatusCode = $status
    if ($type) { $response.ContentType = $type }
    if ($body) { $response.ContentLength64 = $body.Length; $response.OutputStream.Write($body, 0, $body.Length) }
    $response.Close()
}
function Handle($context) {
    $request = $context.Request; $response = $context.Response
    $token = $request.Headers['X-Tercet-Token']
    $requests.Add(@{ Method = $request.HttpMethod; Path = $request.Url.AbsolutePath; Token = $token; IfNoneMatch = $request.Headers['If-None-Match'] })
    switch ($request.Url.AbsolutePath) {
        '/Tercet/tercet.html' { Send $response 200 'text/html; charset=utf-8' $pageBytes; return }
        '/js/app-usage.js' { Send $response 200 'application/javascript' ([Text.Encoding]::UTF8.GetBytes('// stub')); return }
        '/api/tercet' {
            if ($request.HttpMethod -ne 'GET') { Send $response 405 'text/plain' $null; return }
            if (-not $token) { Send $response 400 'text/plain' ([Text.Encoding]::UTF8.GetBytes('Missing X-Tercet-Token header.')); return }
            switch ($token) {
                $demoToken {
                    $response.Headers['ETag'] = $etag
                    $response.Headers['Last-Modified'] = $lastModified.ToString('R')
                    if ($request.Headers['If-None-Match'] -eq $etag) { Send $response 304 $null $null; return }
                    Send $response 200 'application/json; charset=utf-8' $demoBytes; return
                }
                $schemaToken { Send $response 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":2,"queue":[]}')); return }
                $failToken { Send $response 503 'text/plain' ([Text.Encoding]::UTF8.GetBytes('Queue storage is unavailable.')); return }
                default { Send $response 404 $null $null; return }
            }
        }
        default { Send $response 404 $null $null }
    }
}
# Server běží v hlavním vlákně: čeká na požadavek po 100 ms a mezitím hlídá,
# zda Edge neskončil. Rozpracované čekání (Task) přežívá mezi scénáři, jinak
# by zahozený Task spolkl první požadavek dalšího běhu.
$script:pending = $null
function Serve-Until($process) {
    while (-not $process.HasExited) {
        if ($null -eq $script:pending -or $script:pending.IsCompleted) { $script:pending = $listener.GetContextAsync() }
        while (-not $script:pending.Wait(100)) { if ($process.HasExited) { break } }
        if (-not $script:pending.IsCompleted) { break }
        Handle $script:pending.Result
        $script:pending = $null
    }
}
# Vlastní profil drží běh mimo uživatelův Edge; --virtual-time-budget nechá
# doběhnout fetch a časovače, než se DOM vypíše. Headless Edge (starý i nový
# režim, verze 154) nejde zúžit pod 492 CSS px — menší --window-size dá týž
# layout a jen ořízne snímek (změřeno 2026-09-26); 492 je tedy nejužší
# „telefon“, který lze vykreslit, --force-device-scale-factor to nemění.
function Invoke-Edge([string]$name, [string]$url, [switch]$Screenshot) {
    $out = Join-Path $testDir "$name.out"; $err = Join-Path $testDir "$name.err"
    $arguments = @('--headless', '--disable-gpu', '--no-first-run', "--user-data-dir=$(Join-Path $testDir 'profile')",
        '--enable-logging=stderr', '--v=0', '--virtual-time-budget=4000', '--window-size=492,915')
    $arguments += if ($Screenshot) { "--screenshot=$(Join-Path $testDir "$name.png")" } else { '--dump-dom' }
    $arguments += $url
    $process = Start-Process -FilePath $edge -ArgumentList $arguments -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
    Serve-Until $process
    $process.WaitForExit()
    # Edge hlásí konzoli jako řádky INFO:CONSOLE; zajímají nás jen ty ze stránky
    # (zdroj na našem serveru), ne z vlastních komponent prohlížeče.
    $console = @(Select-String -Path $err -Pattern 'CONSOLE' | Where-Object { $_.Line -match "127\.0\.0\.1:$port" } | ForEach-Object { $_.Line })
    return @{ Dom = (Get-Content $out -Raw -Encoding utf8); Console = $console }
}
$base = "http://127.0.0.1:$port/Tercet/tercet.html"
try {
    # A) Demodata: počty řádků, skupin, blikajících diod, patička, čistá konzole.
    $requests.Clear()
    $result = Invoke-Edge 'demo' "$base`?theme=light#$demoToken"
    $dom = $result.Dom
    Assert ($dom.Contains('Community café')) 'Unicode title was not preserved in the rendered page'
    Assert ($result.Console.Count -eq 0) "Console is not clean: $($result.Console -join "`n")"
    Assert (([regex]::Matches($dom, '<div class="row ')).Count -eq $rows.Count) "Rows rendered: expected $($rows.Count)"
    Assert (([regex]::Matches($dom, '<div class="row group"')).Count -eq @($rows | Where-Object { $_.Kind -eq 'group' }).Count) 'Group rows'
    Assert (([regex]::Matches($dom, '<div class="row compositeTask"')).Count -eq @($rows | Where-Object { $_.Kind -eq 'compositeTask' }).Count) 'Composite rows'
    Assert (([regex]::Matches($dom, 'class="dot blink"')).Count -eq $blinking.Count) "Blinking dots: expected $($blinking.Count)"
    Assert (([regex]::Matches($dom, 'class="dot"')).Count -eq ($tasks.Count - $blinking.Count)) 'Static dots'
    foreach ($situation in $desktop.Keys) {
        $expected = @($tasks | Where-Object { $_.Situation -eq $situation }).Count
        Assert (([regex]::Matches($dom, "data-situation=`"$situation`"")).Count -eq $expected) "Rows with situation $situation"
        Assert ($dom.Contains("title=`"$($desktop[$situation][1])`"")) "Tooltip for $situation"
    }
    Assert ($dom.Contains('style="--depth: 2;"')) 'Third level indentation'
    Assert ($dom -match '<span class="unit">hr</span>' -and $dom -match '<span class="unit">day</span>') 'Perspective labels'
    Assert ($dom.Contains("<span id=`"count`">$($tasks.Count) tasks</span>")) "Footer count $($tasks.Count) tasks"
    Assert ($dom -match '<span id="modified" class="muted">\S+') 'Last-Modified shown in header'
    Assert ($dom -match '<div id="status" class="status" hidden(="")?>') 'Status must stay hidden on success'
    Assert ($dom.Contains('<html lang="en" data-app-id="tercet" data-theme="light">')) 'Theme guard applied'
    $api = @($requests | Where-Object { $_.Path -eq '/api/tercet' })
    Assert ($api.Count -eq 1 -and $api[0].Token -eq $demoToken -and -not $api[0].IfNoneMatch) 'First load: one GET with token, no If-None-Match'
    "PASS: demo data rendered ($($rows.Count) rows, $($tasks.Count) tasks, $($blinking.Count) blinking), console clean"

    # B) Neznámý token → 404 a hláška bez řádků.
    $result = Invoke-Edge 'unknown' "$base#$unknownToken"
    Assert ($result.Dom.Contains('No queue exists for this link.') -and -not $result.Dom.Contains('<div class="row ')) '404 message'
    Assert ($result.Console.Count -eq 0) "Console not clean on 404: $($result.Console -join "`n")"
    # C) Neznámá schemaVersion.
    $result = Invoke-Edge 'schema' "$base#$schemaToken"
    Assert ($result.Dom.Contains('Unsupported queue format (schemaVersion 2)')) 'Unsupported schema message'
    # D) Server selhal (503).
    $result = Invoke-Edge 'fail' "$base#$failToken"
    Assert ($result.Dom.Contains('(HTTP 503)')) 'Server failure message'
    # E) Bez tokenu: založení fronty, lísteček skrytý.
    $requests.Clear()
    $result = Invoke-Edge 'create' $base
    Assert ($result.Dom -match '<section id="create">' -and $result.Dom -match '<section id="note" class="note" aria-label="Tercet queue" hidden') 'Create section without token'
    Assert (@($requests | Where-Object { $_.Path -eq '/api/tercet' }).Count -eq 0) 'No API call without token'
    'PASS: 404, unsupported schema, server failure and create page'

    # F) Snímky Light/Dark pro ruční přijetí (stejná data, 492 × 915).
    Invoke-Edge 'demo-light' "$base`?theme=light#$demoToken" -Screenshot | Out-Null
    Invoke-Edge 'demo-dark' "$base`?theme=dark#$demoToken" -Screenshot | Out-Null
    foreach ($name in 'demo-light', 'demo-dark') {
        Assert ((Get-Item (Join-Path $testDir "$name.png")).Length -gt 1024) "Screenshot $name is empty"
    }
    "PASS: screenshots in $testDir (demo-light.png, demo-dark.png)"
}
finally {
    $listener.Stop(); $listener.Close()
    if (-not $KeepArtifacts) { Remove-Item -Recurse -Force $testDir }
}
