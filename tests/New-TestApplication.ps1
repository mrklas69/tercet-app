param([Parameter(Mandatory)][Reflection.Assembly]$Assembly)
# Společný bootstrap testovací WPF aplikace; dot-sourcuje ho Check-Editor.ps1
# a Check-DesktopRefresh.ps1; totéž v C# dělá tests/DesktopProcess/Program.cs.
# Po dot-source je v proměnné $app hotová TestApplication.
#
# Proč takhle: první průchod dispatcheru vyvolává OnStartup i bez
# Application.Run. Testovací podtřída (TestApplication.cs) ho proto potlačí,
# ale zdědí metody App. WPF LoadComponent odmítá BAML do podtřídy z jiné
# assembly; načteme proto skutečný App.xaml se změnou pouze kořenového
# typu, nikoli jeho nastavení (ThemeMode, resources zůstávají produkční).
# Start bez ručního ThemeMode: jeho přepnutí dříve skrylo chybu.
Add-Type -Path (Join-Path $PSScriptRoot 'TestApplication.cs') -ReferencedAssemblies @(
    $Assembly.Location, [Windows.Application].Assembly.Location, [Windows.DependencyObject].Assembly.Location)
[xml]$appMarkup = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Tercet/App.xaml') -Raw
$appMarkup.DocumentElement.RemoveAttribute('Class', 'http://schemas.microsoft.com/winfx/2006/xaml')
$testNamespace = 'clr-namespace:Tercet.Checks;assembly=' + [Tercet.Checks.TestApplication].Assembly.GetName().Name
$markup = $appMarkup.OuterXml.Replace('<Application ', ('<checks:TestApplication xmlns:checks="' + $testNamespace + '" ')).Replace('</Application>', '</checks:TestApplication>')
$app = [Windows.Markup.XamlReader]::Parse($markup)
