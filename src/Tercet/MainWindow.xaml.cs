using System.Windows;

namespace Tercet;

/// <summary>
/// Pasivní okno poskytuje HWND pro DesktopHost. Samotný obsah má společný
/// QueueView, který editor hostí přímo ve svém vlastním aktivovatelném okně.
/// </summary>
public partial class MainWindow : Window
{
    public QueueView View { get; }
    public Size ContentSize => View.ContentSize;

    public MainWindow(IReadOnlyList<QueueRow> rows)
    {
        InitializeComponent();
        View = new QueueView(rows);
        Content = View;
    }
}
