using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Threading;

namespace BotSpeaker;

public sealed class RecallView : UserControl
{
    private readonly AppModel model;
    private readonly RecallController controller;
    private readonly StackPanel root = new(), controls = new(), configuration = new(), setup = new();
    private string selectedMeeting = "";
    private bool meetingReady;
    private readonly TextBlock meetingSummary = new() { TextWrapping = TextWrapping.Wrap };
    private readonly bool settingsOnly;
    public event EventHandler? SettingsRequested;
    private readonly PasswordBox key = new() { Padding = new Thickness(5), MinHeight = 28 };
    private readonly PasswordBox meetingPasscode = new() { Padding = new Thickness(5), MinHeight = 28 };
    private readonly ComboBox region = new() { ItemsSource = RecallController.Regions };
    private readonly TextBlock message = new() { TextWrapping = TextWrapping.Wrap }, scopeHint = new(), voiceHint = new() { TextWrapping = TextWrapping.Wrap };
    private readonly DataGrid bots = new() { AutoGenerateColumns = false, IsReadOnly = true, CanUserAddRows = false, SelectionMode = DataGridSelectionMode.Single, SelectionUnit = DataGridSelectionUnit.FullRow, Height = 125, HeadersVisibility = DataGridHeadersVisibility.Column, Margin = new Thickness(0, 6, 0, 4) };
    private readonly TextBox meeting = new() { Padding = new Thickness(5), MinHeight = 28 }, name = new() { Text = "BotSpeaker" }, speech = new() { AcceptsReturn = true, Height = 125, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(5), TextWrapping = TextWrapping.Wrap }, interval = new() { Text = "0", Width = 65, Padding = new Thickness(5), MinHeight = 28 };
    private readonly ComboBox voice = new() { DisplayMemberPath = "DisplayName", SelectedValuePath = "Id", MinWidth = 220, Height = 24, Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(0, 0, 10, 0), VerticalContentAlignment = VerticalAlignment.Center, IsTextSearchEnabled = true };
    private readonly RadioButton now = new() { Content = "Now", VerticalAlignment = VerticalAlignment.Center, IsChecked = true, Margin = new Thickness(0, 0, 16, 0) }, scheduled = new() { Content = "Schedule", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
    private readonly DatePicker date = new() { SelectedDate = DateTime.Today, Width = 125, Height = 30, VerticalContentAlignment = VerticalAlignment.Center, Margin = new Thickness(0,0,8,0) };
    private readonly ComboBox hour = new() { ItemsSource = Enumerable.Range(0,24).Select(i => i.ToString("00")), Width = 50, Height = 30, VerticalContentAlignment = VerticalAlignment.Center }, minute = new() { ItemsSource = Enumerable.Range(0,60).Select(i => i.ToString("00")), Width = 50, Height = 30, VerticalContentAlignment = VerticalAlignment.Center };
    private readonly StackPanel timestamp = new() { Orientation = Orientation.Horizontal };
    private readonly CheckBox loop = new() { Content = "Loop until cancelled", Margin = new Thickness(18,0,0,0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock repeatLabel = new() { Text = "1", Width = 35, TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel counter = new() { Orientation = Orientation.Horizontal };
    private int repeatCount = 1;
    private readonly ListBox jobs = new() { DisplayMemberPath = "Label", SelectedValuePath = "Id", Height = 90 };
    private readonly DispatcherTimer botRefreshTimer = new() { Interval = TimeSpan.FromSeconds(10) };
    private bool refreshingBots;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Dictionary<string, string> drafts = [];
    private List<BotRow> allBots = [];
    private string? previousBot;
    private bool filtering;
    private sealed record Row(string Id, string Label);
    private sealed record BotRow(string Id, string Name, string Status, string MeetingId) { public string ShortId => Id[..Math.Min(8, Id.Length)]; }
    private static readonly string[] Sentences = ["I am ready to help test the meeting audio. I will speak at a steady pace so that everyone can check the sound and follow the conversation.\n\nFor our first task, let us agree on one useful outcome for today. We can collect ideas, compare a few options, and choose a clear next step together.\n\nBefore we finish, we will recap the decision and name the person responsible for following up. That way, everyone leaves with the same understanding and a practical plan.", "I look forward to hearing everyone's ideas. A thoughtful question can reveal something we have missed, so let us leave room for different perspectives.\n\nImagine we are planning a small community garden. We need to choose a location, decide what to grow, and work out how to share the watering schedule.\n\nA simple plan will help us get started without making everything perfect on the first day. We can learn from the first few weeks and make improvements as we go.", "Today is a good day to turn ideas into action. Let us start by describing the problem in plain language and checking that we all mean the same thing.\n\nNext, we can identify one small experiment that would teach us something useful. We should agree on what success looks like and how we will measure the result.\n\nOnce the experiment is complete, we can review the evidence together. Whether the result is encouraging or surprising, it will help us make a better decision about what comes next."];

    public RecallView(AppModel model, bool settingsOnly = false)
    {
        this.model = model; controller = model.Recall; this.settingsOnly = settingsOnly;
        meeting.Text = model.Settings.LastRecallMeeting;
        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        root.Margin = new Thickness(20);
        var heading = new DockPanel();
        root.Children.Add(heading);
        if (!settingsOnly)
        {
            var settings = new Button { Content = "⚙", FontSize = 16, ToolTip = "Settings", Style = (Style)FindResource("IconButton") };
            System.Windows.Automation.AutomationProperties.SetName(settings, "Settings");
            settings.Click += (_, _) => SettingsRequested?.Invoke(this, EventArgs.Empty);
            DockPanel.SetDock(settings, Dock.Right); heading.Children.Add(settings);
        }
        heading.Children.Add(new TextBlock { Text = settingsOnly ? "Recall settings" : "Recall Bot", FontSize = settingsOnly ? 15 : 22, FontWeight = FontWeights.Bold });
        root.Children.Add(configuration);
        Field(configuration, "Recall API key (blank keeps the existing key)", key);
        region.SelectedItem = controller.Region; Field(configuration, "Recall workspace region", region);
        configuration.Children.Add(MakeButton("Validate & save key", async () => { await controller.HandleAsync("configure", new() { ["apiKey"] = key.Password, ["region"] = region.SelectedItem?.ToString() }); key.Clear(); Render(); }));
        root.Children.Add(message); root.Children.Add(setup); root.Children.Add(controls);
        setup.Children.Add(new TextBlock { Text = "Choose a meeting", FontSize = 18, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0,18,0,8) });
        Field(setup, "Meeting link, ID, or invitation", meeting);
        meeting.AcceptsReturn = true;
        meeting.TextWrapping = TextWrapping.Wrap;
        meeting.MaxHeight = 100;
        meeting.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        meeting.TextChanged += (_, _) => meetingPasscode.Clear();
        DataObject.AddPastingHandler(meeting, (_, e) => {
            if (e.DataObject.GetData(DataFormats.UnicodeText) is string pasted)
            {
                ApplyMeetingPaste(pasted);
                e.CancelCommand();
            }
        });
        setup.Children.Add(MakeButton("Paste invitation", () => {
            if (!Clipboard.ContainsText()) throw new AppException("Copy a meeting invitation or join link first.");
            ApplyMeetingPaste(Clipboard.GetText());
            return Task.CompletedTask;
        }));
        Field(setup, "Teams passcode", meetingPasscode);
        setup.Children.Add(new TextBlock { Text = "Paste the entire Teams invitation to fill in its meeting ID and passcode, or enter them separately. Join links already include the required details.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0,6,0,10) });
        setup.Children.Add(MakeButton("Continue", async () => {
            var value = await controller.ResolveMeetingUrlAsync(meeting.Text, meetingPasscode.Password);
            model.Settings.LastRecallMeeting = value; model.Settings.Save();
            selectedMeeting = value; meetingReady = true;
            meetingSummary.Text = "Meeting " + RecallController.MeetingId(selectedMeeting);
            allBots = []; FilterBots(); Render(); await Refresh();
        }));
        var meetingHeader = new DockPanel { Margin = new Thickness(0,8,0,8) };
        var changeMeeting = MakeButton("Change meeting", () => { meetingReady = false; Render(); meeting.Focus(); return Task.CompletedTask; });
        DockPanel.SetDock(changeMeeting, Dock.Right); meetingHeader.Children.Add(changeMeeting); meetingHeader.Children.Add(meetingSummary); controls.Children.Add(meetingHeader);
        bots.Columns.Add(new DataGridTextColumn { Header = "Bot", Binding = new Binding("Name"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
        bots.Columns.Add(new DataGridTextColumn { Header = "Status", Binding = new Binding("Status"), Width = 160 });
        bots.Columns.Add(new DataGridTextColumn { Header = "ID", Binding = new Binding("ShortId"), Width = 85 });
        bots.SelectedValuePath = "Id"; bots.SelectionChanged += (_, _) => { if (!filtering) SelectDraft(); };
        controls.Children.Add(bots); controls.Children.Add(scopeHint);
        var botActions = new StackPanel { Orientation = Orientation.Horizontal };
        botActions.Children.Add(MakeButton("Add bot", async () => {
            var botName = PromptBotName();
            if (botName == null) return;
            name.Text = botName;
            var result = await controller.HandleAsync("add", new() { ["meetingUrl"] = selectedMeeting, ["name"] = botName });
            await Refresh(); bots.SelectedValue = result["bot"]?["id"]?.GetValue<string>();
        }));
        botActions.Children.Add(MakeButton("Refresh bots", Refresh));
        botActions.Children.Add(MakeButton("Remove selected bot", async () => { await controller.HandleAsync("remove", new() { ["botId"] = SelectedBot().Id }); await Refresh(); })); controls.Children.Add(botActions);
        Field(controls, "Speech", speech);
        speech.Text = Starter(name.Text);
        voice.Margin = new Thickness(0, 8, 0, 6);
        System.Windows.Automation.AutomationProperties.SetName(voice, "Voice");
        controls.Children.Add(voice); controls.Children.Add(voiceHint);
        controls.Children.Add(MakeButton("New sample", () => { speech.Text = Starter((bots.SelectedItem as BotRow)?.Name ?? name.Text); return Task.CompletedTask; }));
        var dispatch = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0,10,0,10) };
        dispatch.Children.Add(new TextBlock { Text = "Dispatch  ", VerticalAlignment = VerticalAlignment.Center }); dispatch.Children.Add(now); dispatch.Children.Add(scheduled);
        var initial = DateTime.Now.AddMinutes(5); date.SelectedDate = initial.Date; hour.SelectedIndex = initial.Hour; minute.SelectedIndex = initial.Minute;
        timestamp.Children.Add(date); timestamp.Children.Add(hour); timestamp.Children.Add(new TextBlock { Text = ":", VerticalAlignment = VerticalAlignment.Center }); timestamp.Children.Add(minute); timestamp.Children.Add(new TextBlock { Text = " local time", VerticalAlignment = VerticalAlignment.Center }); dispatch.Children.Add(timestamp); controls.Children.Add(dispatch);
        now.Checked += (_, _) => timestamp.IsEnabled = false; scheduled.Checked += (_, _) => timestamp.IsEnabled = true; timestamp.IsEnabled = false;
        var repeats = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0,4,0,4) };
        repeats.Children.Add(new TextBlock { Text = "Repeat  ", VerticalAlignment = VerticalAlignment.Center });
        counter.Children.Add(MakeButton("−", () => { repeatCount = Math.Max(1,repeatCount-1); repeatLabel.Text = repeatCount.ToString(); return Task.CompletedTask; })); counter.Children.Add(repeatLabel); counter.Children.Add(MakeButton("+", () => { repeatCount = Math.Min(10000,repeatCount+1); repeatLabel.Text = repeatCount.ToString(); return Task.CompletedTask; })); repeats.Children.Add(counter); repeats.Children.Add(loop); controls.Children.Add(repeats);
        loop.Checked += (_, _) => counter.IsEnabled = false; loop.Unchecked += (_, _) => counter.IsEnabled = true;
        var gap = new StackPanel { Orientation = Orientation.Horizontal }; gap.Children.Add(new TextBlock { Text = "Extra gap between clips (seconds)  ", VerticalAlignment = VerticalAlignment.Center }); gap.Children.Add(interval); controls.Children.Add(gap);
        controls.Children.Add(MakeButton("Speak / schedule", async () => {
            if (voice.SelectedItem is not ElevenLabsVoice chosen) throw new AppException("Select an ElevenLabs voice from the list.");
            var body = new JsonObject { ["botId"] = SelectedBot().Id, ["text"] = speech.Text, ["at"] = DispatchTime(), ["loop"] = loop.IsChecked == true, ["interval"] = double.Parse(interval.Text, System.Globalization.CultureInfo.InvariantCulture), ["voice"] = chosen.Id };
            if (loop.IsChecked != true) body["repeat"] = repeatCount;
            await controller.HandleAsync("speak", body); Render();
        }));
        controls.Children.Add(new TextBlock { Text = "Keep the app running and awake. Playback may start after dispatch. Cancel stops future sends; audio already sent may continue.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0,6,0,6) });
        controls.Children.Add(jobs); controls.Children.Add(MakeButton("Cancel selected speech job", async () => { await controller.HandleAsync("cancel", new() { ["id"] = jobs.SelectedValue?.ToString() }); Render(); }));
        botRefreshTimer.Tick += async (_, _) => {
            if (settingsOnly || !IsVisible || !meetingReady || !controller.Configured || refreshingBots) return;
            try { await Refresh(); } catch (Exception error) { message.Text = "Bot refresh failed: " + error.Message; }
        };
        timer.Tick += (_, _) => Render();
        Loaded += async (_, _) => { Render(); timer.Start(); if (!settingsOnly) botRefreshTimer.Start(); if (!settingsOnly) { await model.LoadVoicesIfNeededAsync(); FilterVoices(); FilterBots(); } };
        Unloaded += (_, _) => { timer.Stop(); botRefreshTimer.Stop(); };
    }
    private string? PromptBotName()
    {
        var input = new TextBox { Text = "BotSpeaker", MaxLength = 100, MinHeight = 28, Padding = new Thickness(5), Margin = new Thickness(0,8,0,16) };
        var panel = new StackPanel { Margin = new Thickness(20) };
        var dialog = new Window { Title = "Add bot", Owner = Window.GetWindow(this), Content = panel, Width = 380, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        panel.Children.Add(new TextBlock { Text = "Bot name", FontSize = 16, FontWeight = FontWeights.SemiBold }); panel.Children.Add(input);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = "Cancel", IsCancel = true, Padding = new Thickness(12,6,12,6), Margin = new Thickness(0,0,8,0) };
        var add = new Button { Content = "Add bot", IsDefault = true, Padding = new Thickness(12,6,12,6) };
        input.TextChanged += (_, _) => add.IsEnabled = !string.IsNullOrWhiteSpace(input.Text);
        add.Click += (_, _) => dialog.DialogResult = true;
        actions.Children.Add(cancel); actions.Children.Add(add); panel.Children.Add(actions);
        dialog.Loaded += (_, _) => { input.Focus(); input.SelectAll(); };
        return dialog.ShowDialog() == true ? input.Text.Trim() : null;
    }
    private static string Starter(string botName) => $"Hi I am {botName}, {Sentences[Random.Shared.Next(Sentences.Length)]}";
    private void ApplyMeetingPaste(string text)
    {
        var parsed = RecallController.ParseMeetingInput(text);
        meeting.Text = parsed.Meeting;
        meetingPasscode.Password = parsed.Passcode;
        message.Text = "";
    }

    private BotRow SelectedBot() => bots.SelectedItem as BotRow ?? throw new AppException("Select a bot in this meeting first.");
    private string DispatchTime()
    {
        if (now.IsChecked == true) return "now";
        if (date.SelectedDate is not DateTime day || hour.SelectedIndex < 0 || minute.SelectedIndex < 0) throw new AppException("Choose a date and time.");
        var local = DateTime.SpecifyKind(day.Date.AddHours(hour.SelectedIndex).AddMinutes(minute.SelectedIndex), DateTimeKind.Unspecified);
        if (TimeZoneInfo.Local.IsInvalidTime(local) || TimeZoneInfo.Local.IsAmbiguousTime(local)) throw new AppException("Choose an unambiguous local time outside the daylight-saving transition.");
        return new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local)).ToString("O");
    }
    private void SelectDraft()
    {
        if (previousBot != null) drafts[previousBot] = speech.Text;
        previousBot = (bots.SelectedItem as BotRow)?.Id;
        if (bots.SelectedItem is BotRow row) speech.Text = drafts.GetValueOrDefault(row.Id) ?? Starter(row.Name);
    }
    private async Task Refresh()
    {
        if (refreshingBots) return;
        var scope = selectedMeeting;
        if (string.IsNullOrWhiteSpace(scope)) { allBots = []; FilterBots(); return; }
        refreshingBots = true;
        try
        {
            var response = await controller.HandleAsync("list", new() { ["meetingId"] = scope });
            if (scope != selectedMeeting) return;
            allBots = response["bots"]!.AsArray().Select(b => new BotRow(b!["id"]!.GetValue<string>(), b["bot_name"]?.GetValue<string>() ?? "BotSpeaker", b["status"]?.GetValue<string>() ?? "unknown", b["meeting_id"]?.GetValue<string>() ?? "")).ToList(); FilterBots();
            if (message.Text.StartsWith("Bot refresh failed: ")) message.Text = "";
        }
        finally { refreshingBots = false; }
    }
    private void FilterBots()
    {
        var id = RecallController.MeetingId(selectedMeeting);
        var selected = (bots.SelectedItem as BotRow)?.Id;
        var visible = allBots.Where(b => id.Length > 0 && b.MeetingId == id && b.Status != "done").ToArray();
        filtering = true; bots.ItemsSource = visible; bots.SelectedValue = selected;
        if (bots.SelectedItem == null && visible.Length > 0) bots.SelectedIndex = 0;
        filtering = false;
        if ((bots.SelectedItem as BotRow)?.Id != previousBot) SelectDraft();
        scopeHint.Text = id.Length == 0 ? "Enter a meeting URL or ID, then refresh." : $"{visible.Length} unfinished bots · meeting {id}";
        scopeHint.TextWrapping = TextWrapping.Wrap;
    }
    private void FilterVoices()
    {
        var selected = voice.SelectedValue?.ToString() ?? model.VoiceId;
        voice.ItemsSource = model.Voices.ToArray();
        voice.SelectedValue = selected;
        if (voice.SelectedItem == null && voice.Items.Count > 0) voice.SelectedIndex = 0;
        voiceHint.Text = model.VoiceLoadError ?? (voice.Items.Count == 0 ? "No voices available. Refresh to load voices." : "");
    }
    private void Render()
    {
        configuration.Visibility = settingsOnly || !controller.Configured ? Visibility.Visible : Visibility.Collapsed;
        setup.Visibility = !settingsOnly && controller.Configured && !meetingReady ? Visibility.Visible : Visibility.Collapsed;
        controls.Visibility = !settingsOnly && controller.Configured && meetingReady ? Visibility.Visible : Visibility.Collapsed;
        var selected = jobs.SelectedValue;
        jobs.ItemsSource = controller.Status()["jobs"]!.AsArray().Select(j => new Row(j!["id"]!.GetValue<string>(), $"{j["status"]} · {j["dispatched"]} sent · {j["text"]} {j["error"]}")).ToArray(); jobs.SelectedValue = selected;
    }
    private static void Field(Panel parent, string label, Control control) { parent.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0,8,0,3), TextWrapping = TextWrapping.Wrap }); parent.Children.Add(control); }
    private Button MakeButton(string title, Func<Task> action)
    {
        var button = new Button { Content = title, HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(10,4,10,4), Margin = new Thickness(0,3,6,3) };
        button.Click += async (_, _) => { button.IsEnabled = false; message.Text = ""; try { await action(); } catch (Exception error) { message.Text = error.Message; } finally { button.IsEnabled = true; } }; return button;
    }
}
