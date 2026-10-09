# Společný render vektorové ikony (resources/application-icon.xaml)
# do PNG dané velikosti. Dot-sourcují ho Build-ApplicationIcon.ps1 (ICO
# s pevnou sadou rozměrů) a Build-Msix.ps1 (loga balíčku).
# WPF načte předlohu přímo; každý rozměr se renderuje z geometrie, nikoli
# zmenšením větší bitmapy. $PSScriptRoot je adresář tohoto souboru (scripts/).
Add-Type -AssemblyName PresentationCore, PresentationFramework
$script:applicationIconSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'resources/application-icon.xaml'
$script:applicationIconDrawing = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText($script:applicationIconSource))

# Vrací bajty PNG. Čárka před polem (`,$bytes`) je nutná: PowerShell by jinak
# pole bajtů „rozbalil" do roury po jednom a volající by dostal sadu čísel.
function ConvertTo-ApplicationIconPng([int]$Size) {
    $visual = [Windows.Media.DrawingVisual]::new()
    $context = $visual.RenderOpen()
    $context.DrawImage($script:applicationIconDrawing, [Windows.Rect]::new(0, 0, $Size, $Size))
    $context.Close()
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($Size, $Size, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.MemoryStream]::new()
    try {
        $encoder.Save($stream)
        return ,$stream.ToArray()
    } finally { $stream.Dispose() }
}
