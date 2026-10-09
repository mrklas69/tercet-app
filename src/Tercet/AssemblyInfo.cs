using System.Windows;

// Atribut assembly popisuje celé sestavení. WPF podle něj hledá výchozí
// styly ovládacích prvků, pokud je nenajde přímo v okně nebo aplikaci.
[assembly: ThemeInfo(
    ResourceDictionaryLocation.None,          // Samostatné slovníky motivů nemáme.
    ResourceDictionaryLocation.SourceAssembly // Obecný slovník se hledá v tomto sestavení.
)]
