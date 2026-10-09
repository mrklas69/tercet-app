using System.Windows;
using System.Windows.Controls;

namespace Tercet;

/// <summary>
/// Dotaz při konfliktu synchronizace: fronta se změnila na tomto
/// počítači i na serveru. Dialog pouze vrací volbu; soubory a server mění
/// QueueSynchronizer až po zavření. Stavba a chování zrcadlí QueueRecoveryWindow.
/// </summary>
internal sealed class QueueConflictWindow : Window
{
    // Výchozí volba je Cancel: křížek, Escape i Enter nic nemění.
    public ConflictChoice Choice { get; private set; } = ConflictChoice.Cancel;

    public QueueConflictWindow(SyncConflict conflict)
    {
        Title = ApplicationIdentity.Title("Queue conflict");
        SetResourceReference(IconProperty, "ApplicationIcon");
        Width = 520;
        MaxWidth = SystemParameters.WorkArea.Width;
        MaxHeight = SystemParameters.WorkArea.Height;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        SetResourceReference(BackgroundProperty, "ApplicationBackgroundBrush");
        SetResourceReference(ForegroundProperty, "TextFillColorPrimaryBrush");
        var body = new StackPanel { Margin = new Thickness(20) };
        body.Children.Add(new TextBlock
        {
            Text = conflict.FirstSync
                ? "The queue on this computer and the queue on the server differ."
                : "The queue was changed both on this computer and on the server.",
            FontWeight = FontWeights.SemiBold, FontSize = 16, TextWrapping = TextWrapping.Wrap
        });
        body.Children.Add(new TextBlock
        {
            Text = (conflict.FirstSync
                ? "They have not been synchronized with each other yet, so Tercet cannot tell which one is current."
                : "Both were edited since they were last synchronized, so neither can be merged automatically.")
                + "\n\nKeep this computer's queue: the server's version is replaced (the server keeps its previous version)."
                + "\nTake the server's queue: this computer's version is replaced (the previous version stays in queue.json.bak)."
                + "\nCancel: nothing changes; synchronize again after deciding.",
            Margin = new Thickness(0, 12, 0, 12), TextWrapping = TextWrapping.Wrap
        });
        if (conflict.ServerModified is { } modified)
        {
            // Čas změny na serveru převedený do místního času uživatele.
            body.Children.Add(new TextBlock
            {
                Text = "Server version from " + modified.ToLocalTime().ToString("g") + ".",
                TextWrapping = TextWrapping.Wrap
            });
        }
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 18, 0, 0)
        };
        var keepLocal = new Button { Content = "Keep this computer's queue", Padding = new Thickness(12, 5, 12, 5) };
        var takeServer = new Button { Content = "Take the server's queue", Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(10, 0, 0, 0) };
        var cancel = new Button
        {
            Content = "Cancel", IsDefault = true, IsCancel = true,
            Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(10, 0, 0, 0)
        };
        keepLocal.Click += (_, _) => { Choice = ConflictChoice.KeepLocal; DialogResult = true; };
        takeServer.Click += (_, _) => { Choice = ConflictChoice.TakeServer; DialogResult = true; };
        cancel.Click += (_, _) => DialogResult = false;
        actions.Children.Add(keepLocal);
        actions.Children.Add(takeServer);
        actions.Children.Add(cancel);
        body.Children.Add(actions);
        Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Loaded += (_, _) => cancel.Focus();
    }
}
