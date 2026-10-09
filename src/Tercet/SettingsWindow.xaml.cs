using System.IO;
using System.Windows;

namespace Tercet;

/// <summary>
/// Nastavení odkazu na frontu. Okno jen ověří tvar odkazu a předá
/// ho aplikaci; zápis souboru a spuštění sladění řeší App v callbacku.
/// Chyba (tvar i zápis) zůstane v okně, stejně jako u editoru.
/// </summary>
public partial class SettingsWindow : Window
{
    // Action<string?> je předaná metoda bez návratové hodnoty; null = bez odkazu.
    private readonly Action<string?> apply;

    public SettingsWindow(string? currentLink, string status, Action<string?> apply)
        : this(currentLink, status, apply, DataLocation.IsPackaged) { }

    // Výslovná hodnota umožní testovat oba distribuční režimy v témže hostu;
    // běžné volání výše ji vždy bere ze skutečné identity procesu.
    public SettingsWindow(string? currentLink, string status, Action<string?> apply, bool isPackaged)
    {
        this.apply = apply;
        InitializeComponent();
        Title = ApplicationIdentity.Title("Settings");
        LinkBox.Text = currentLink ?? "";
        StatusText.Text = status;
        UninstallNotice.Visibility = isPackaged ? Visibility.Visible : Visibility.Collapsed;
        SaveButton.Click += (_, _) => SaveAndClose();
        CancelButton.Click += (_, _) => Close();
        Loaded += (_, _) => { LinkBox.Focus(); LinkBox.SelectAll(); };
    }

    private void SaveAndClose()
    {
        string text = LinkBox.Text.Trim();
        string? link = text.Length == 0 ? null : text;
        try
        {
            // Parse jen ověřuje; ukládá se text tak, jak ho uživatel vložil.
            if (link is not null) QueueLink.Parse(link);
            apply(link);
        }
        catch (FormatException ex)
        {
            ShowError(ex.Message);
            return;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            ShowError("The settings could not be saved. " + ex.Message);
            return;
        }
        Close();
    }

    private void ShowError(string message)
    {
        ErrorText.Text = "Not saved: " + message;
        ErrorText.Visibility = Visibility.Visible;
        LinkBox.Focus();
    }
}
