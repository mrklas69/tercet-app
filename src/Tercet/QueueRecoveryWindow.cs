using System.Windows;
using System.Windows.Controls;

namespace Tercet;

/// <summary>
/// Potvrzení obnovy zálohy před vznikem lístečku. Pouze vrací souhlas; soubory
/// obnovuje QueueStore až po zavření dialogu a nové kontrole jejich obsahu.
/// </summary>
internal sealed class QueueRecoveryWindow : Window
{
    public QueueRecoveryWindow(QueueRecovery recovery)
    {
        Title = ApplicationIdentity.Title("Restore backup");
        SetResourceReference(IconProperty, "ApplicationIcon");
        Width = 480;
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
            Text = recovery.IsMissing ? "The queue file is missing." : "The queue file is invalid.",
            FontWeight = FontWeights.SemiBold, FontSize = 16, TextWrapping = TextWrapping.Wrap
        });
        body.Children.Add(new TextBlock
        {
            Text = "A valid backup is available. Restoring it returns the entire queue and archive to the previous saved state. Changes made after that state will not be included."
                + "\n\nThe backup will be kept."
                + (recovery.IsMissing ? "" : " The invalid file will be preserved as a separate copy.")
                + " Restoration is saved immediately.",
            Margin = new Thickness(0, 12, 0, 12), TextWrapping = TextWrapping.Wrap
        });
        body.Children.Add(new TextBlock { Text = recovery.FilePath, TextWrapping = TextWrapping.Wrap });
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 18, 0, 0)
        };
        var restore = new Button { Content = "Restore backup", Padding = new Thickness(12, 5, 12, 5) };
        var exit = new Button
        {
            Content = "Exit", IsDefault = true, IsCancel = true,
            Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(10, 0, 0, 0)
        };
        // DialogResult ukončí ShowDialog. Křížek ani Escape nenastaví true;
        // App proto pokračuje jen po výslovném stisku Restore backup.
        restore.Click += (_, _) => DialogResult = true;
        exit.Click += (_, _) => DialogResult = false;
        actions.Children.Add(restore);
        actions.Children.Add(exit);
        body.Children.Add(actions);
        Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        // Výchozí Enter je bezpečný i po běžném otevření: focus patří Exit.
        Loaded += (_, _) => exit.Focus();
    }
}
