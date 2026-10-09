param([Tercet.App]$Application, [byte[]]$Bytes, [string]$TestDirectory, [Reflection.Assembly]$Assembly)
# Dílčí sada hlavního Check-Editor.ps1: blikající diody pasivního lístečku.
# Pracuje jen s demodaty v paměti; provozní frontu neotevírá.
# Sdílí Assert z hlavního skriptu přes dot-sourcing. Jména prvků tuple (BlinkSeconds,
# Description) zná jen kompilátor C#; za běhu má ValueTuple jen Item1..Item4.
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$describe = [Tercet.QueueAttention].GetMethod('Describe')
$attention = [Tercet.QueueView].GetMethod('Attention', [Reflection.BindingFlags]'Static,NonPublic')

# Tempo je součástí společné palety: rychlost kóduje naléhavost, statické
# zůstávají neaktivní a hotové úkoly i prázdná fronta (null přes reflexi,
# přímé volání by PowerShell převedl na prázdný řetězec).
$expectedPeriod = @{ needsAttention = 1; underReview = 2; inProgress = 4; inactive = 0; done = 0 }
foreach ($situation in $expectedPeriod.Keys) {
    Assert ([Tercet.QueueAttention]::Describe($situation).Item4 -eq $expectedPeriod[$situation]) "Blink period: $situation"
}
Assert ($describe.Invoke($null, [object[]]@($null)).Item4 -eq 0) 'Empty queue must not blink'
'PASS: blink periods red 1 s, orange 2 s, green 4 s, gray and blue static'

# Pasivní lísteček: každý blikající řádek má vlastní Storyboard s omezenou
# snímkovou frekvencí; statické situace mají jen diodu bez svatozáře.
$document = [Tercet.QueueDocument]::Parse($Bytes)
$rows = $document.Rows()
$blinkingRows = @($rows | Where-Object { $_.Kind -ne 'group' -and [Tercet.QueueAttention]::Describe($_.Situation).Item4 -gt 0 })
$staticRows = @($rows | Where-Object { $_.Kind -ne 'group' -and [Tercet.QueueAttention]::Describe($_.Situation).Item4 -eq 0 })
Assert ($blinkingRows.Count -gt 0 -and $staticRows.Count -gt 0) 'Demo data must contain blinking and static situations'
$window = [Tercet.MainWindow]::new($rows)
$view = $window.View
# Animace startují až v Loaded a hodiny hlásí Stopped do prvního ticku WPF
# TimeManageru, který přijde jen s vykreslovaným oknem (změřeno 2026-09-12).
# Lísteček se proto krátce zobrazí bez aktivace; zavření na konci ověří
# zastavení animace.
$blinkers = [Tercet.QueueView].GetField('blinkers', $flags).GetValue($view)
Assert ($blinkers.Count -eq $blinkingRows.Count) "Storyboards: $($blinkers.Count), blinking rows: $($blinkingRows.Count)"
# Nespuštěný Storyboard nemá na objektu hodiny: dotaz na stav vyhodí výjimku.
foreach ($storyboard in $blinkers) {
    Reject { $storyboard.GetCurrentState($view) } ([InvalidOperationException])
}
$window.ShowActivated = $false
$window.Show()
$view.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
Assert ($blinkers.Count -eq $blinkingRows.Count) 'Loaded changed the storyboard list'
foreach ($storyboard in $blinkers) {
    Assert ($storyboard.GetCurrentState($view) -eq [Windows.Media.Animation.ClockState]::Active) 'Blink is not running'
    Assert ([Windows.Media.Animation.Timeline]::GetDesiredFrameRate($storyboard) -eq 10) 'Frame rate is not limited to 10 fps'
    Assert ($storyboard.AutoReverse -and $storyboard.RepeatBehavior -eq [Windows.Media.Animation.RepeatBehavior]::Forever) 'Blink must fade back and repeat forever'
    Assert ($storyboard.Children.Count -eq 2) 'Blink animates the lit dot and the halo'
    foreach ($fade in $storyboard.Children) {
        Assert ($fade.EasingFunction -is [Windows.Media.Animation.SineEase]) 'Blink must ease in and out'
    }
}
$panels = @($view.FindName('QueueGrid').Children | Where-Object { $_ -is [Windows.Controls.DockPanel] })
Assert ($panels.Count -eq $rows.Count) 'One name panel per row'
$litDots = @{}
for ($index = 0; $index -lt $rows.Count; $index++) {
    $row = $rows[$index]
    $first = $panels[$index].Children[0]
    if ($row.Kind -eq 'group') {
        Assert ($first -isnot [Windows.Shapes.Ellipse] -and $first -isnot [Windows.Controls.Grid]) "Group has a dot: $($row.Title)"
        continue
    }
    $base = $attention.Invoke($null, [object[]]@($row.Situation)).Item1.Color
    if ([Tercet.QueueAttention]::Describe($row.Situation).Item4 -gt 0) {
        Assert ($first -is [Windows.Controls.Grid] -and $first.Children.Count -eq 3) "Blinking dot needs three layers: $($row.Title)"
        $dim = $first.Children[0]; $halo = $first.Children[1]; $lit = $first.Children[2]
        Assert ($lit.Fill -is [Windows.Media.RadialGradientBrush] -and $lit.Fill.IsFrozen) "Lit dot brush: $($row.Title)"
        # Maximum blikání je světlejší než základní barva: tělo svítící
        # vrstvy má každou složku RGB vyšší nebo rovnou základu a alespoň jednu vyšší.
        $litBody = $lit.Fill.GradientStops[1].Color
        Assert ($litBody.R -ge $base.R -and $litBody.G -ge $base.G -and $litBody.B -ge $base.B -and ($litBody.R + $litBody.G + $litBody.B) -gt ($base.R + $base.G + $base.B)) "Lit dot is not brighter than the palette: $($row.Situation)"
        Assert ($halo.Fill -is [Windows.Media.RadialGradientBrush] -and $halo.Width -eq 14 -and -not $halo.IsHitTestVisible) "Halo: $($row.Title)"
        # Zhaslá dioda je tmavší odstín téhož tónu. Rozptyl složek RGB hlídá,
        # že nezešedla: šedá je vyhrazena situaci Inactive.
        $dimColor = $dim.Fill.Color
        Assert ($dimColor.R -le $base.R -and $dimColor.G -le $base.G -and $dimColor.B -le $base.B) "Dim dot is not darker: $($row.Situation)"
        $spread = [math]::Max($dimColor.R, [math]::Max($dimColor.G, $dimColor.B)) - [math]::Min($dimColor.R, [math]::Min($dimColor.G, $dimColor.B))
        Assert ($spread -ge 20) "Dim dot looks gray: $($row.Situation)"
        Assert ($first.Width -eq 14 -and $first.Margin.Left -eq -2 -and $first.Margin.Right -eq 1) 'Frame must keep the 13 px name offset'
        Assert ($dim.ToolTip -ceq $lit.ToolTip -and $lit.ToolTip -ceq [Tercet.QueueAttention]::Describe($row.Situation).Item2) "Dot tooltip: $($row.Title)"
        $litDots[$row.Title] = $lit
    } else {
        Assert ($first -is [Windows.Shapes.Ellipse] -and $first.Fill -is [Windows.Media.RadialGradientBrush]) "Static LED dot: $($row.Title)"
        Assert ($first.Width -eq 10 -and $first.Margin.Right -eq 3) "Static dot size: $($row.Title)"
    }
}
'PASS: passive note runs one 10 fps storyboard per blinking row, static LEDs elsewhere'

# Posun animace na půl periody musí diodu zhasnout a návrat na začátek ji
# rozsvítit; SeekAlignedToLastTick nastaví hodnoty hned, bez čekání na tick.
function Set-BlinkPhase([double]$fraction) {
    foreach ($storyboard in $blinkers) {
        $half = $storyboard.Children[0].Duration.TimeSpan
        $storyboard.SeekAlignedToLastTick($view, [TimeSpan]::FromTicks([long]($half.Ticks * $fraction)), [Windows.Media.Animation.TimeSeekOrigin]::BeginTime)
    }
}
Set-BlinkPhase 1
foreach ($lit in $litDots.Values) { Assert ($lit.Opacity -lt 0.05) 'Lit dot did not fade out at half period' }
Set-BlinkPhase 0
foreach ($lit in $litDots.Values) { Assert ($lit.Opacity -gt 0.95) 'Lit dot did not return at period start' }
'PASS: seek to half period dims, seek to start lights'

# Náhledy obou fází v obou motivech pro oko: dioda i zhaslý stav musí být
# rozlišitelné na světlém i tmavém podkladu. Motiv se na konci vrací na System.
# Seek změní Opacity v property systému, ale RenderTargetBitmap kreslí stav
# posledního render ticku (změřeno 2026-09-12: obě fáze vyšly bajtově shodně).
# Animace se proto pozastaví, posune a před renderem proběhne tick na
# prioritě Render; rozdíl fází hlídá porovnání hashů obou PNG.
# Změna motivu vyvolá na obsahu okna Unloaded a Loaded (změřeno 2026-09-12):
# blikání musí běžet dál se stejnými storyboardy, pauza proto přijde až po ní.
$size = $window.ContentSize
foreach ($mode in 'Light','Dark') {
    $Application.ThemeMode = [Windows.ThemeMode].GetProperty($mode).GetValue($null)
    $view.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
    Assert ($blinkers.Count -eq $blinkingRows.Count) "Theme change changed the storyboard list: $mode"
    foreach ($storyboard in $blinkers) {
        Assert ($storyboard.GetCurrentState($view) -eq [Windows.Media.Animation.ClockState]::Active) "Theme change stopped the blink: $mode"
        $storyboard.Pause($view)
    }
    $hashes = @{}
    foreach ($phase in @(@{ Name = 'lit'; Fraction = 0 }, @{ Name = 'dim'; Fraction = 1 })) {
        Set-BlinkPhase $phase.Fraction
        $view.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
        $view.Measure($size)
        $view.Arrange([Windows.Rect]::new($size))
        $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int][math]::Ceiling($size.Width * 3), [int][math]::Ceiling($size.Height * 3), 288, 288, [Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($view)
        $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $previewPath = Join-Path $TestDirectory ('blink-{0}-{1}.png' -f $mode.ToLower(), $phase.Name)
        $output = [IO.File]::Create($previewPath)
        try { $encoder.Save($output) } finally { $output.Dispose() }
        $hashes[$phase.Name] = (Get-FileHash -LiteralPath $previewPath -Algorithm SHA256).Hash
        "Blink preview: $previewPath"
    }
    Assert ($hashes['lit'] -ne $hashes['dim']) "Lit and dim previews are identical: $mode"
}
foreach ($storyboard in $blinkers) { $storyboard.Resume($view) }
$Application.ThemeMode = [Windows.ThemeMode]::System
$view.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
foreach ($storyboard in $blinkers) {
    Assert ($storyboard.GetCurrentState($view) -eq [Windows.Media.Animation.ClockState]::Active) 'Return to System theme stopped the blink'
}
'PASS: lit and dim previews differ in Light and Dark, blink survives theme changes'

# Zavření zobrazeného lístečku zastaví hodiny animace (Unloaded), aby
# Storyboard Forever nepřežil okno. Seznam zůstává pro případné Loaded.
$window.Close()
$view.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
Assert ($blinkers.Count -eq $blinkingRows.Count) 'Closing changed the storyboard list'
foreach ($storyboard in $blinkers) {
    Assert ($storyboard.GetCurrentState($view) -eq [Windows.Media.Animation.ClockState]::Stopped) 'Storyboard survived the closed note'
}
'PASS: closing the note stops every blink'

# Editor: stejná dioda, ale bez blikání a svatozáře; puntíky v nabídce
# situací zůstávají plné (paleta systray) a volba situace dá diodu.
$editorView = [Tercet.QueueView]::new($document.Clone())
Assert ([Tercet.QueueView].GetField('blinkers', $flags).GetValue($editorView).Count -eq 0) 'Editor must not blink'
$editorPanels = @($editorView.FindName('QueueGrid').Children | Where-Object { $_ -is [Windows.Controls.DockPanel] })
$taskIndex = -1
for ($index = 0; $index -lt $rows.Count; $index++) {
    if ($rows[$index].Kind -ne 'group' -and $rows[$index].Situation -cne 'needsAttention') { $taskIndex = $index; break }
}
Assert ($taskIndex -ge 0) 'Demo data has no task to switch to Needs attention'
$editorDot = $editorPanels[$taskIndex].Children[0]
Assert ($editorDot -is [Windows.Shapes.Ellipse] -and $editorDot.Fill -is [Windows.Media.RadialGradientBrush]) 'Editor dot is not an LED'
Assert ($editorDot.Width -eq 10 -and $editorDot.Margin.Right -eq 3) 'Editor dot size'
foreach ($item in $editorDot.ContextMenu.Items) {
    if ($item -is [Windows.Controls.MenuItem] -and $null -ne $item.Icon) {
        Assert ($item.Icon.Fill -is [Windows.Media.SolidColorBrush]) "Menu icon must stay flat: $($item.Header)"
    }
}
$red = @($editorDot.ContextMenu.Items | Where-Object { $_ -is [Windows.Controls.MenuItem] -and $_.Header -ceq 'Needs attention' })[0]
$red.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
Assert ($editorDot.Fill -is [Windows.Media.RadialGradientBrush] -and $editorDot.ToolTip -ceq 'Needs attention') 'Situation change lost the LED look'
$expectedRed = $attention.Invoke($null, [object[]]@('needsAttention')).Item1.Color
Assert ($editorDot.Fill.GradientStops[1].Color -eq $expectedRed) 'LED body color differs from the palette'
'PASS: editor keeps LED dots static, flat menu icons, situation change keeps the LED look'
