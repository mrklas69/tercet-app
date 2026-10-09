using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using System.Text.Json.Nodes;

namespace Tercet;

/// <summary>
/// Pasivní kompaktní náhled fronty s odsazenými úrovněmi a barevnými diodami.
/// V editačním režimu (s pracovní kopií) tentýž renderer přidá vstupní prvky
/// a menu struktury; po každé strukturální operaci se tělo překreslí znovu
/// z pracovní kopie, protože pořadí řádků se změnilo.
/// </summary>
public partial class QueueView : UserControl
{
    private readonly QueueDocument? workingCopy;
    private IReadOnlyList<JsonObject>? editableItems;
    // Vstup názvu podle položky pracovní kopie: po přidání řádku do něj dáme focus.
    // JsonObject nepřepisuje Equals, slovník proto porovnává odkazy (identitu objektu).
    private readonly Dictionary<JsonObject, TextBox> titleInputs = new(ReferenceEqualityComparer.Instance);
    // Animace blikání, spouštěné v Loaded a zastavované v Unloaded.
    // Storyboard s RepeatBehavior Forever by jinak přežil zavřené okno: hodiny
    // animace drží WPF TimeManager, dokud je někdo nezastaví. Obě události
    // přijdou i při změně motivu Windows (WPF obsah okna odpojí a znovu
    // připojí; změřeno 2026-09-12), proto se po Unloaded seznam nemaže
    // a Loaded animace znovu spustí. Seznam je jen v pasivním režimu neprázdný.
    private readonly List<Storyboard> blinkers = new();

    // Událost (event) je seznam obslužných metod, které si zaregistruje okolí
    // (+=) a které renderer zavolá po překreslení z pracovní kopie. EventHandler
    // je standardní delegát (odesílatel, argumenty); ? říká, že bez odběratele
    // je hodnota null. Editor podle ní přizpůsobí výšku okna obsahu.
    public event EventHandler? ContentChanged;

    public QueueView(IReadOnlyList<QueueRow> rows) : this(rows, null) { }

    // Editor vždy odvodí řádky ze své kopie; nelze omylem předat řádky
    // jiného dokumentu a přiřadit vstupy k nesprávným položkám.
    public QueueView(QueueDocument workingCopy) : this(workingCopy.Rows(), workingCopy) { }

    // Stejný renderer pro oba režimy: editor vymění text za vstupní prvek,
    // ale ponechá pořadí, rozměry, barvy i umístění těla lístečku.
    private QueueView(IReadOnlyList<QueueRow> rows, QueueDocument? workingCopy)
    {
        this.workingCopy = workingCopy;
        InitializeComponent();
        // Volná plocha těla (pod posledním řádkem, vpravo od krátkého názvu)
        // vkládá na konec technického kořene; řádek první úrovně jde přidat
        // i volbou „za tento řádek" u kteréhokoli kořenového řádku.
        if (workingCopy is not null) AttachStructureMenu(Body, null);
        // Loaded přijde po zobrazení okna lístečku, Unloaded při jeho zavření
        // (editor otevírá vlastní okno a plocha se po chybě znovu připojuje
        // novým oknem, App.MaintainDesktop) i při změně motivu.
        Loaded += (_, _) => StartBlinking();
        Unloaded += (_, _) => StopBlinking();
        Render(rows);
    }

    // Překreslení z pracovní kopie po vložení nebo odstranění položky.
    // V pasivním režimu (bez kopie) není co překreslovat.
    public void Rebuild()
    {
        if (workingCopy is null) return;
        Render(workingCopy.Rows());
        // ?.Invoke zavolá odběratele jen tehdy, když se někdo přihlásil.
        ContentChanged?.Invoke(this, EventArgs.Empty);
    }

    private void Render(IReadOnlyList<QueueRow> rows)
    {
        StopBlinking();
        blinkers.Clear();
        QueueGrid.Children.Clear();
        QueueGrid.RowDefinitions.Clear();
        titleInputs.Clear();
        editableItems = workingCopy?.QueueItems();
        foreach (var row in rows)
            AddRow(row);
        if (rows.Count == 0)
        {
            // Prázdná fronta nemá žádný řádek; pravé tlačítko obslouží menu Body.
            QueueGrid.Children.Add(new TextBlock { Text = "The queue is empty." });
        }
    }

    // Výšku odvodíme měřením obsahu, šířku omezuje stejná mřížka jako v maketě.
    // Nativní host ještě rozměry omezí skutečnou pracovní plochou monitoru.
    public Size ContentSize
    {
        get
        {
            QueueGrid.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            return new Size(QueueGrid.DesiredSize.Width + 10, QueueGrid.DesiredSize.Height + 6);
        }
    }

    // DockPanel nejprve vyhradí místo značce, poslednímu dítěti (názvu) dá zbytek.
    // Díky tomu TextTrimming vytvoří výpustku i u dlouhého názvu na třetí úrovni.
    private void AddRow(QueueRow row)
    {
        int index = QueueGrid.RowDefinitions.Count;
        JsonObject? editableItem = editableItems?[index];
        QueueGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(17.5) });
        // Samotný MaxWidth sloupce nestačí: při prvním měření bez omezení
        // by DockPanel převzal plnou délku textu a WPF by jej pouze ořízlo.
        var name = new DockPanel
        {
            Margin = new Thickness(row.Depth * 10, 0, 0, 0), MaxWidth = 210 - row.Depth * 10
        };
        if (row.Kind == "group")
        {
            // Podklad vzniká před textem, takže leží pod ním. ColumnSpan pokryje
            // i perspektivu a záporný okraj prodlouží pruh přes vnitřní padding.
            // Odstín značí hloubku skupiny; nejde o situaci pracovního úkolu.
            var band = new Border
            {
                Margin = new Thickness(-4, 0, -4, 0), IsHitTestVisible = false
            };
            // SetResourceReference je kódový protějšek DynamicResource v XAML:
            // drží odkaz na klíč motivu, nikoli kopii barvy platné při startu.
            band.SetResourceReference(Border.BackgroundProperty, row.Depth switch
            {
                0 => "AccentFillColorDefaultBrush",
                1 => "SolidBackgroundFillColorBaseAltBrush",
                _ => "SolidBackgroundFillColorSecondaryBrush"
            });
            Grid.SetRow(band, index);
            Grid.SetColumnSpan(band, 3);
            QueueGrid.Children.Add(band);
        }
        else
        {
            var (color, description) = Attention(row.Situation!);
            // Kolečko vypadá jako LED dioda v obou režimech (odlesk, tmavší okraj);
            // blikání a svatozář přidává jen pasivní lísteček níže.
            var dot = new Ellipse
            {
                Width = 10, Height = 10, Fill = LedBrush(color), Margin = new Thickness(0, 0, 3, 0),
                VerticalAlignment = VerticalAlignment.Center, ToolTip = description
            };
            if (editableItem is not null)
            {
                var menu = new ContextMenu();
                foreach (string situation in QueueValues.Situations)
                {
                    var appearance = Attention(situation);
                    // Icon je vyhrazený sloupec WPF menu. Stejný 10px puntík
                    // jako v řádku doplňuje název situace ze společné palety.
                    var choice = new MenuItem
                    {
                        Header = appearance.Description,
                        Icon = new Ellipse { Width = 10, Height = 10, Fill = appearance.Color }
                    };
                    choice.Click += (_, _) =>
                    {
                        editableItem["situation"] = situation;
                        var chosen = Attention(situation);
                        dot.Fill = LedBrush(chosen.Color);
                        dot.ToolTip = chosen.Description;
                    };
                    menu.Items.Add(choice);
                }
                menu.Items.Add(new Separator());
                var assignee = new MenuItem { Header = "Assignee…" };
                assignee.Click += (_, _) => EditAssignee(editableItem, dot);
                menu.Items.Add(assignee);
                dot.ContextMenu = menu;
                dot.Cursor = Cursors.Hand;
                dot.MouseLeftButtonDown += (_, e) => { menu.PlacementTarget = dot; menu.IsOpen = true; e.Handled = true; };
            }
            double blinkSeconds = QueueAttention.Describe(row.Situation).BlinkSeconds;
            // Editor bliká záměrně ne: pohyb vedle právě psaného textu ruší
            // a menu situací zůstává statické (A3). Statické situace mají jen diodu.
            name.Children.Add(editableItem is null && blinkSeconds > 0
                ? BlinkingDot(dot, color, blinkSeconds) : dot);
        }
        var label = new TextBlock
        {
            Text = row.Title, ToolTip = row.Title, TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            FontWeight = row.Kind is "group" or "compositeTask" ? FontWeights.SemiBold : FontWeights.Normal
        };
        // Akcent má vlastní odpovídající text: v tmavém motivu může být černý,
        // v kontrastním motivu se obě barvy přizpůsobí uživatelově systémové volbě.
        if (row.Kind == "group" && row.Depth == 0)
            label.SetResourceReference(TextBlock.ForegroundProperty, "TextOnAccentFillColorPrimaryBrush");
        if (editableItem is null) name.Children.Add(label);
        else
        {
            var title = new TextBox
            {
                Text = row.Title, ToolTip = row.Title, BorderThickness = new Thickness(0),
                Padding = new Thickness(0), MinHeight = 0, Height = 17.5,
                Background = Brushes.Transparent, FontWeight = label.FontWeight,
                VerticalContentAlignment = VerticalAlignment.Center
            };
            string textKey = row.Kind == "group" && row.Depth == 0
                ? "TextOnAccentFillColorPrimaryBrush" : "TextFillColorPrimaryBrush";
            // Fluent při najetí myší a focusu překryje podklad řádku vlastním
            // podkladem vstupu. Text i kurzor musí přejít na jeho odpovídající
            // barvu; trvalá bílá z akcentu by na světlém vstupu zmizela.
            void UpdateInputColors()
            {
                string currentKey = title.IsKeyboardFocused ? "TextControlForegroundFocused"
                    : title.IsMouseOver ? "TextControlForegroundPointerOver" : textKey;
                title.SetResourceReference(TextBox.ForegroundProperty, currentKey);
                title.SetResourceReference(TextBox.CaretBrushProperty, currentKey);
            }
            // Text názvu v okamžiku vstupu do pole; Escape se k němu vrátí.
            // Lokální proměnná přežívá v uzávěru (closure) obslužných lambd.
            string focusedText = row.Title;
            title.MouseEnter += (_, _) => UpdateInputColors();
            title.MouseLeave += (_, _) => UpdateInputColors();
            title.GotKeyboardFocus += (_, _) => { focusedText = title.Text; UpdateInputColors(); };
            title.LostKeyboardFocus += (_, _) => UpdateInputColors();
            UpdateInputColors();
            title.TextChanged += (_, _) =>
            {
                editableItem["title"] = title.Text;
                title.ToolTip = title.Text;
            };
            // Enter ukončí editaci názvu: odebere klávesový focus, takže se vrátí
            // barvy řádku. Změna už je v kopii z TextChanged; Uložit je zvlášť.
            // Escape navíc vrátí text platný při vstupu do pole; zápis
            // do kopie obstará týž TextChanged. Editor se nezavírá.
            title.KeyDown += (_, e) =>
            {
                if (e.Key == Key.Escape) title.Text = focusedText;
                else if (e.Key != Key.Enter) return;
                Keyboard.ClearFocus();
                e.Handled = true;
            };
            // Pravé tlačítko na názvu nahradí výchozí schránkové menu TextBoxu
            // menu struktury: přidání, převody, posun, přesun a odstranění.
            AttachStructureMenu(title, editableItem);
            titleInputs[editableItem] = title;
            name.Children.Add(title);
        }
        Grid.SetRow(name, index);
        QueueGrid.Children.Add(name);

        var unit = new TextBlock
        {
            Text = row.Perspective is null ? "" : PerspectiveLabel(row.Perspective),
            FontSize = 12,
            TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center
        };
        unit.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
        if (editableItem is not null && row.Kind != "group")
        {
            var menu = new ContextMenu();
            foreach (string value in QueueValues.Perspectives)
            {
                string text = PerspectiveLabel(value);
                var choice = new MenuItem { Header = text };
                choice.Click += (_, _) => { editableItem["perspective"] = value; unit.Text = text; };
                menu.Items.Add(choice);
            }
            unit.ContextMenu = menu;
            unit.Cursor = Cursors.Hand;
            unit.MouseLeftButtonDown += (_, e) => { menu.PlacementTarget = unit; menu.IsOpen = true; e.Handled = true; };
        }
        Grid.SetRow(unit, index);
        Grid.SetColumn(unit, 2);
        QueueGrid.Children.Add(unit);
    }

    // Menu se skládá až při otevření: situace předků se mění kolečkem bez
    // překreslení, takže nabídka musí odpovídat aktuálnímu stavu kopie.
    // Položka null značí technický kořen (prázdná fronta).
    private void AttachStructureMenu(FrameworkElement target, JsonObject? item)
    {
        // ContextMenu dědí písmo z prvku, na kterém visí: název skupiny a celku
        // je SemiBold, takže by menu bylo tučné jen u nich. Menu má jednotnou váhu.
        var menu = new ContextMenu { FontWeight = FontWeights.Normal };
        target.ContextMenu = menu;
        target.ContextMenuOpening += (_, _) => FillStructureMenu(menu, item);
    }

    private void FillStructureMenu(ContextMenu menu, JsonObject? item)
    {
        var document = workingCopy!;
        menu.Items.Clear();
        if (item is null)
        {
            menu.Items.Add(new MenuItem { Header = "End of top level", IsEnabled = false });
            AddInsertChoice(menu, "Add task at the end", "task", created => document.AppendChild(null, created));
            AddInsertChoice(menu, "Add group at the end", "group", created => document.AppendChild(null, created));
            return;
        }
        // Neaktivní titulek říká, co řádek je: uživatel jinak z odsazení nepozná
        // typ ani úroveň (A4). Slova Group / Composite task / Task jsou z glosáře.
        string kind = item["kind"]!.GetValue<string>();
        string typeName = kind switch { "group" => "Group", "compositeTask" => "Composite task", _ => "Task" };
        string inside = kind == "group" ? "into this group" : "into this composite task";
        string title = item["title"]?.GetValue<string>() ?? "";
        menu.Items.Add(new MenuItem { Header = LiteralMenuHeader($"{typeName} “{title}” · level {document.Depth(item) + 1}"), IsEnabled = false });
        // Nepovolené vložení se nezobrazí; pravidla dává model.
        var parent = document.ParentOf(item);
        if (document.CanInsertInto(parent, "task"))
            AddInsertChoice(menu, "Add task after this row", "task", created => document.InsertAfter(item, created));
        if (document.CanInsertInto(parent, "group"))
            AddInsertChoice(menu, "Add group after this row", "group", created => document.InsertAfter(item, created));
        if (document.CanInsertInto(item, "task"))
            AddInsertChoice(menu, $"Add task {inside}", "task", created => document.AppendChild(item, created));
        if (document.CanInsertInto(item, "group"))
            AddInsertChoice(menu, $"Add group {inside}", "group", created => document.AppendChild(item, created));
        // Převody typu: úkol → celek, aby šly přidat části; celek bez
        // částí → úkol. Nabízí se jen tam, kde model převod dovolí.
        if (document.CanSplit(item))
            AddConvertChoice(menu, "Split into parts", item, document.SplitIntoParts);
        if (document.CanMerge(item))
            AddConvertChoice(menu, "Merge into task", item, document.MergeIntoTask);
        menu.Items.Add(new Separator());
        // Posun na okraji seznamu zůstává vidět, jen zašedlý: volba existuje
        // vždy, jen teď nemá kam (na rozdíl od vložení, které typ zakazuje).
        AddMoveChoice(menu, "Move up", item, -1);
        AddMoveChoice(menu, "Move down", item, +1);
        AddMoveToChoice(menu, item);
        menu.Items.Add(new Separator());
        // Archivovat: skupina volbu nemá (typ), nehotová práce ji vidí
        // zašedlou (stav) — stejná konvence jako Posunout na okraji seznamu.
        if (kind != "group")
        {
            var archive = new MenuItem { Header = "Archive", IsEnabled = document.CanArchive(item) };
            archive.Click += (_, _) =>
            {
                if (!document.CanArchive(item)) return;
                document.Archive(item);
                Rebuild();
            };
            menu.Items.Add(archive);
        }
        var remove = new MenuItem { Header = "Delete…" };
        remove.Click += (_, _) => RemoveWithConfirmation(item);
        menu.Items.Add(remove);
    }

    // Archiv: modální seznam vlastněný editorem, stejný vzor jako
    // dialog Řešitel. Obnovit mění jen pracovní kopii; dialog se zavře a focus
    // jde na obnovený název, aby bylo vidět, kam se položka vrátila.
    public void ShowArchive()
    {
        JsonObject? restored = null;
        var dialog = new Window
        {
            Title = ApplicationIdentity.Title("Archive"), Width = 380, SizeToContent = SizeToContent.Height, MaxHeight = 420,
            ResizeMode = ResizeMode.NoResize, Owner = Window.GetWindow(this),
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false
        };
        dialog.SetResourceReference(Window.IconProperty, "ApplicationIcon");
        dialog.SetResourceReference(BackgroundProperty, "ApplicationBackgroundBrush");
        dialog.SetResourceReference(ForegroundProperty, "TextFillColorPrimaryBrush");
        var close = new Button { Content = "Close", IsCancel = true, Margin = new Thickness(8), Padding = new Thickness(7, 0, 7, 0), HorizontalAlignment = HorizontalAlignment.Right };
        var panel = new DockPanel();
        DockPanel.SetDock(close, Dock.Bottom);
        panel.Children.Add(close);
        panel.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = BuildArchiveList(entry => { restored = workingCopy!.Restore(entry); dialog.DialogResult = true; })
        });
        dialog.Content = panel;
        dialog.ShowDialog();
        if (restored is null) return;
        Rebuild();
        FocusTitle(restored, selectAll: false);
    }

    // Seznam záznamů nejnovější nahoře (A4): uloženo se přidává na konec, výpis
    // pole obrací. Řádek nese název, počet položek podstromu a cíl obnovy
    // podle modelu; volání `restore` dostane vybraný záznam.
    private FrameworkElement BuildArchiveList(Action<JsonObject> restore)
    {
        var document = workingCopy!;
        var list = new StackPanel { Margin = new Thickness(8) };
        var entries = document.ArchiveEntries();
        if (entries.Count == 0)
        {
            list.Children.Add(new TextBlock { Text = "The archive is empty." });
            return list;
        }
        foreach (var entry in entries.Reverse())
        {
            var item = QueueDocument.ArchivedItem(entry);
            int count = document.SubtreeCount(item);
            var (parent, _) = document.RestorePlacement(entry);
            // Dva Run v jednom TextBlocku: název v základní barvě, detail v druhotné.
            // Vlastnost Text takový obsah nezná (čte jen holý text, ne Inlines),
            // proto tooltip skládáme z týchž řetězců zvlášť.
            string title = item["title"]?.GetValue<string>() ?? "";
            string detailText = (count == 1 ? "" : $" · {count} items")
                + " · " + (parent is null ? "top level" : document.PathOf(parent));
            var label = new TextBlock { VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = title + detailText };
            label.Inlines.Add(new Run(title));
            var detail = new Run(detailText);
            detail.SetResourceReference(TextElement.ForegroundProperty, "TextFillColorSecondaryBrush");
            label.Inlines.Add(detail);
            var button = new Button { Content = "Restore", Margin = new Thickness(8, 2, 0, 2), Padding = new Thickness(7, 0, 7, 0) };
            button.Click += (_, _) => restore(entry);
            var row = new DockPanel { LastChildFill = true };
            DockPanel.SetDock(button, Dock.Right);
            row.Children.Add(button);
            row.Children.Add(label);
            list.Children.Add(row);
        }
        return list;
    }

    // Převod mění typ na místě; překreslení vymění kolečko a tučnost řádku.
    private void AddConvertChoice(ContextMenu menu, string header, JsonObject item, Action<JsonObject> convert)
    {
        var choice = new MenuItem { Header = header };
        choice.Click += (_, _) =>
        {
            convert(item);
            Rebuild();
            FocusTitle(item, selectAll: false);
        };
        menu.Items.Add(choice);
    }

    // Posun celého podstromu mezi sourozenci; po překreslení zůstane
    // focus na posunutém názvu, aby bylo vidět, kam se řádek dostal.
    private void AddMoveChoice(ContextMenu menu, string header, JsonObject item, int delta)
    {
        var document = workingCopy!;
        var choice = new MenuItem { Header = header, IsEnabled = document.CanMove(item, delta) };
        choice.Click += (_, _) =>
        {
            if (!document.TryMove(item, delta)) return;
            Rebuild();
            FocusTitle(item, selectAll: false);
        };
        menu.Items.Add(choice);
    }

    // Přesun k jinému rodiči: podmenu vypíše platné cíle z modelu
    // jako cesty („Workshop › Backlog“), kořen jako „Top level“. Bez cíle je
    // volba zašedlá, ne skrytá: stejně jako Posunout existuje vždy, jen teď
    // nemá kam. Po přesunu zůstane focus na přesunutém názvu.
    private void AddMoveToChoice(ContextMenu menu, JsonObject item)
    {
        var document = workingCopy!;
        var targets = document.MoveTargets(item);
        var choice = new MenuItem { Header = "Move to", IsEnabled = targets.Count > 0 };
        foreach (var target in targets)
        {
            var destination = new MenuItem { Header = LiteralMenuHeader(target is null ? "Top level" : document.PathOf(target)) };
            destination.Click += (_, _) =>
            {
                if (!document.CanMoveTo(item, target)) return;
                document.MoveTo(item, target);
                Rebuild();
                FocusTitle(item, selectAll: false);
            };
            choice.Items.Add(destination);
        }
        menu.Items.Add(choice);
    }

    // WPF chápe podtržítko v menu jako značku klávesové zkratky. Uživatelské
    // názvy mají zůstat doslovné; dvě podtržítka vykreslí jedno. Uložená data
    // se nemění, escapuje se pouze text předaný šabloně MenuItem.
    private static string LiteralMenuHeader(string text) => text.Replace("_", "__");

    // Func/Action jako parametry: volající určí, kam se nová položka vloží,
    // společný zbytek (výchozí název, překreslení, focus) je tady jednou.
    private void AddInsertChoice(ContextMenu menu, string header, string kind, Action<JsonObject> place)
    {
        var choice = new MenuItem { Header = header };
        choice.Click += (_, _) =>
        {
            var created = kind == "group" ? QueueDocument.NewGroup("New group") : QueueDocument.NewTask("New task");
            place(created);
            Rebuild();
            FocusTitle(created, selectAll: true);
        };
        menu.Items.Add(choice);
    }

    // Focus až po průchodu dispatcheru: nový TextBox musí být nejdřív
    // rozložen a připojen k oknu, jinak Keyboard.Focus tiše selže.
    // Výchozí název nové položky je vybraný celý, takže psaní jej rovnou přepíše.
    private void FocusTitle(JsonObject item, bool selectAll)
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            if (!titleInputs.TryGetValue(item, out var input)) return;
            Keyboard.Focus(input);
            if (selectAll) input.SelectAll();
        }), DispatcherPriority.Input);
    }

    // Potvrzení nese název a celkový počet položek podstromu.
    private void RemoveWithConfirmation(JsonObject item)
    {
        var document = workingCopy!;
        int count = document.SubtreeCount(item);
        string title = item["title"]?.GetValue<string>() ?? "";
        string text = count == 1
            ? $"Delete “{title}”?"
            : $"Delete “{title}” including its children?\n{count} items in total.";
        var owner = Window.GetWindow(QueueGrid);
        var result = owner is null
            ? MessageBox.Show(text, ApplicationIdentity.DisplayName, MessageBoxButton.YesNo, MessageBoxImage.Question)
            : MessageBox.Show(owner, text, ApplicationIdentity.DisplayName, MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (result != MessageBoxResult.Yes) return;
        document.Remove(item);
        Rebuild();
    }

    // Řešitel je potřebný pro aktivní situace. Dialog mění pouze pracovní kopii,
    // aby nově zahájený úkol s původním assignee=null šel korektně uložit.
    private static void EditAssignee(JsonObject item, FrameworkElement origin)
    {
        var input = new TextBox { Text = item["assignee"]?.GetValue<string>() ?? "", Margin = new Thickness(8) };
        var confirm = new Button { Content = "OK", IsDefault = true, Margin = new Thickness(8), HorizontalAlignment = HorizontalAlignment.Right };
        var panel = new DockPanel();
        DockPanel.SetDock(confirm, Dock.Bottom);
        panel.Children.Add(confirm);
        panel.Children.Add(input);
        var dialog = new Window
        {
            Title = ApplicationIdentity.Title("Assignee"), Width = 300, Height = 150, ResizeMode = ResizeMode.NoResize,
            Owner = Window.GetWindow(origin), WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Content = panel, ShowInTaskbar = false
        };
        dialog.SetResourceReference(Window.IconProperty, "ApplicationIcon");
        dialog.SetResourceReference(BackgroundProperty, "ApplicationBackgroundBrush");
        dialog.SetResourceReference(ForegroundProperty, "TextFillColorPrimaryBrush");
        confirm.Click += (_, _) => dialog.DialogResult = true;
        if (dialog.ShowDialog() == true)
            item["assignee"] = string.IsNullOrWhiteSpace(input.Text) ? null : input.Text.Trim();
    }

    // Datové hodnoty z QueueValues jsou nezávislé na popiscích UI.
    private static string PerspectiveLabel(string perspective) => perspective switch
    {
        "minutes" => "min", "hours" => "hr", "days" => "day",
        _ => throw new ArgumentException("Unknown perspective.", nameof(perspective))
    };

    // WPF potřebuje Brush, systray GDI barvu. Převod dělá každý renderer,
    // samotné odstíny a popisky mají jediný zdroj v QueueAttention.
    private static (SolidColorBrush Color, string Description) Attention(string situation)
    {
        var appearance = QueueAttention.Describe(situation);
        return (Brush(appearance.Color), appearance.Description);
    }

    private static SolidColorBrush Brush(string hex) => (SolidColorBrush)new BrushConverter().ConvertFromInvariantString(hex)!;

    // Blikající dioda: tři vrstvy v rámečku 14 × 14. Vespod zhaslá
    // dioda (tmavší odstín téhož tónu, nikdy šedá — šedá znamená Inactive),
    // nad ní svítící dioda a kolem ní polopropustná svatozář.
    // Animuje se jen Opacity horních dvou vrstev; štětce jsou zmražené
    // a sdílené, bez bitmapových Effectů, které by se počítaly při každém
    // překreslení. Záporný levý okraj drží název na stejném místě jako
    // u statického kolečka (10 px dioda + 3 px mezera = 13 px).
    private FrameworkElement BlinkingDot(Ellipse lit, SolidColorBrush color, double seconds)
    {
        lit.Margin = new Thickness(0);
        var frame = new Grid
        {
            Width = 14, Height = 14, Margin = new Thickness(-2, 0, 1, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        // Svítící vrstva je světlejší než základní barva: základ tak leží
        // uprostřed přechodu a maximum blikání viditelně zjasní.
        var bright = new SolidColorBrush(Mix(color.Color, Colors.White, 0.35));
        lit.Fill = LedBrush(bright);
        var dim = new Ellipse { Width = 10, Height = 10, Fill = DimBrush(color), ToolTip = lit.ToolTip };
        var halo = new Ellipse { Width = 14, Height = 14, Fill = HaloBrush(bright), IsHitTestVisible = false };
        frame.Children.Add(dim);
        frame.Children.Add(halo);
        frame.Children.Add(lit);
        AddBlink(seconds, lit, halo);
        return frame;
    }

    // Jeden Storyboard na diodu: opacity 1 → 0 za půl periody a AutoReverse
    // zpět, RepeatBehavior Forever. DesiredFrameRate 10 omezuje, jak často
    // WPF animaci vzorkuje a překresluje; výchozích 60 fps by pro puntík
    // 10 px bylo plýtvání.
    // Containing object je tento UserControl, takže Stop a Seek jdou přes něj.
    // Před Loaded se animace jen připraví; v už zobrazeném lístečku (Rebuild)
    // se spustí hned, protože Loaded znovu nepřijde.
    private void AddBlink(double seconds, params UIElement[] targets)
    {
        var storyboard = new Storyboard { RepeatBehavior = RepeatBehavior.Forever, AutoReverse = true };
        Timeline.SetDesiredFrameRate(storyboard, 10);
        foreach (var target in targets)
        {
            // SineEase zpomalí průběh u obou krajů: dioda se u maxima i minima
            // chvíli zdrží a přechod působí plynule i při 10 snímcích za sekundu.
            var fade = new DoubleAnimation(1, 0, TimeSpan.FromSeconds(seconds / 2))
            {
                EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut }
            };
            Storyboard.SetTarget(fade, target);
            Storyboard.SetTargetProperty(fade, new PropertyPath(OpacityProperty));
            storyboard.Children.Add(fade);
        }
        blinkers.Add(storyboard);
        if (IsLoaded) storyboard.Begin(this, true);
    }

    // Begin i opakovaně startuje od začátku, takže po změně motivu blikají
    // všechny diody znovu ve fázi; isControllable dovolí Stop a Seek.
    private void StartBlinking()
    {
        foreach (var storyboard in blinkers)
            storyboard.Begin(this, true);
    }

    private void StopBlinking()
    {
        foreach (var storyboard in blinkers)
            storyboard.Stop(this);
    }

    // Míchání barev po složkách: amount 0 vrátí color, 1 vrátí toward.
    private static Color Mix(Color color, Color toward, double amount) => Color.FromRgb(
        (byte)(color.R + (toward.R - color.R) * amount),
        (byte)(color.G + (toward.G - color.G) * amount),
        (byte)(color.B + (toward.B - color.B) * amount));

    // Radiální gradient s ohniskem mimo střed dává dojem kulaté diody:
    // světlý odlesk vlevo nahoře, plná barva uprostřed, tmavší okraj.
    // Freeze zmrazí štětec: WPF pak nesleduje jeho změny a sdílí ho levně.
    private static Brush LedBrush(SolidColorBrush color)
    {
        var brush = new RadialGradientBrush
        {
            GradientOrigin = new Point(0.35, 0.3), Center = new Point(0.5, 0.5), RadiusX = 0.55, RadiusY = 0.55
        };
        brush.GradientStops.Add(new GradientStop(Mix(color.Color, Colors.White, 0.45), 0));
        brush.GradientStops.Add(new GradientStop(color.Color, 0.55));
        brush.GradientStops.Add(new GradientStop(Mix(color.Color, Colors.Black, 0.3), 1));
        brush.Freeze();
        return brush;
    }

    private static Brush DimBrush(SolidColorBrush color)
    {
        var brush = new SolidColorBrush(Mix(color.Color, Colors.Black, 0.5));
        brush.Freeze();
        return brush;
    }

    // Svatozář: barva diody, do ztracena k okraji. Kreslí se pod diodou,
    // viditelná je jen vnější 2px obruba (poloměr diody je 0,71 poloměru
    // svatozáře), proto gradient začíná plnou sytostí až u okraje diody.
    private static Brush HaloBrush(SolidColorBrush color)
    {
        var brush = new RadialGradientBrush();
        brush.GradientStops.Add(new GradientStop(Color.FromArgb(180, color.Color.R, color.Color.G, color.Color.B), 0.7));
        brush.GradientStops.Add(new GradientStop(Color.FromArgb(0, color.Color.R, color.Color.G, color.Color.B), 1));
        brush.Freeze();
        return brush;
    }
}
