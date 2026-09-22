using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace BotSpeaker;

/// <summary>Retained by the main window so navigation never loses an active run or bot mapping.</summary>
public sealed class RecallMeetingView : UserControl
{
    public event EventHandler? ChooseScriptRequested;
    private readonly AppModel model;
    private readonly OrchestrationController source;
    private readonly string templateId;
    public string TemplateId => templateId;
    private readonly StackPanel root = new(), body = new();
    private readonly TextBlock message = new() { TextWrapping = TextWrapping.Wrap, Margin = new(0,8,0,8) };
    private readonly TextBox meeting = new() { MinHeight = 28, Padding = new(5) };
    private readonly List<Speaker> speakers;
    private readonly List<OrchestratedScriptTurn> turns;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(10) };
    private readonly Dictionary<int, TextBlock> statuses = [];
    private CancellationTokenSource? run;
    private int step;
    private bool busy, refreshing;
    private string selectedMeeting = "";
    private sealed class Speaker
    {
        public required OrchestratedSpeakerConfiguration Configuration;
        public string Name { get => Configuration.Name; set => Configuration.Name = value; }
        public string Voice { get => Configuration.VoiceId; set => Configuration.VoiceId = value; }
        public string Bot = "", Status = "Not added";
    }
    public RecallMeetingView(AppModel model, OrchestrationController source)
    {
        this.model = model; this.source = source; templateId = source.SelectedTemplate.Id;
        speakers = source.SpeakerConfigurations.Select(s => new Speaker {
            Configuration = new() { Slot = s.Slot, Role = s.Role, Name = s.CustomName,
                VoiceId = s.VoiceId, VoiceName = s.VoiceName } }).ToList();
        turns = source.SelectedTemplate.ParseTurns(source.MeetingScriptText);
        meeting.Text = model.Settings.LastRecallMeeting;
        root.Margin = new(22);
        root.Children.Add(new TextBlock { Text = "Recall.ai · " + source.SelectedTemplate.Title, FontSize = 22, FontWeight = FontWeights.Bold, TextWrapping = TextWrapping.Wrap });
        root.Children.Add(message); root.Children.Add(body);
        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        timer.Tick += async (_, _) => { if (step > 0 && !busy) await SafeRefresh(); };
        Loaded += async (_, _) => { timer.Start(); await model.LoadVoicesIfNeededAsync(); Render(); };
        Unloaded += (_, _) => timer.Stop();
        Render();
    }
    private Button Button(string title, Func<Task> action)
    {
        var button = new Button { Content = title, HorizontalAlignment = HorizontalAlignment.Left, Padding = new(12,5,12,5), Margin = new(0,6,8,6), IsEnabled = !busy && run == null };
        if (title is "Continue to bots" or "Arrange turns" or "Start meeting") {
            button.Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(46,107,214));
            button.Foreground = System.Windows.Media.Brushes.White;
            button.BorderThickness = new(0); button.FontWeight = FontWeights.Bold;
        }
        button.Click += async (_, _) => {
            if (busy || run != null) return;
            busy = true; body.IsEnabled = false;
            try { message.Text = ""; await action(); }
            catch (Exception error) { message.Text = error.Message; }
            finally { busy = false; body.IsEnabled = true; Render(); }
        };
        return button;
    }
    private void Render()
    {
        if (run != null) return;
        body.Children.Clear(); statuses.Clear();
        body.Children.Add(new TextBlock { Text = "1  Meeting   →   2  Speaker bots   →   3  Arrange turns", Margin = new(0,8,0,16) });
        if (step == 0)
        {
            body.Children.Add(Button("Back to scripts", () => { ChooseScriptRequested?.Invoke(this, EventArgs.Empty); return Task.CompletedTask; }));
            if (!model.Recall.Configured) body.Children.Add(new RecallView(model, settingsOnly: true));
            body.Children.Add(new TextBlock { Text = "Meeting URL or ID", Margin = new(0,8,0,6) });
            body.Children.Add(meeting);
            body.Children.Add(new TextBlock { Text = "For a new meeting, paste its full invite link, including any passcode.", Margin = new(0,6,0,6) });
            body.Children.Add(Button("Continue to bots", () => {
                if (!model.Recall.Configured) throw new AppException("Configure Recall first.");
                selectedMeeting = meeting.Text.Trim();
                if (selectedMeeting.Length == 0) throw new AppException("Enter a meeting URL or ID.");
                if (selectedMeeting.Contains("://") && (!Uri.TryCreate(selectedMeeting, UriKind.Absolute, out var uri) || uri.Scheme != "https")) throw new AppException("Use an HTTPS meeting URL.");
                model.Settings.LastRecallMeeting = selectedMeeting; model.Settings.Save(); step = 1;
                return Task.CompletedTask;
            }));
            return;
        }
        body.Children.Add(new TextBlock { Text = "Meeting " + RecallController.MeetingId(selectedMeeting), Margin = new(0,0,0,10) });
        if (step == 1)
        {
            body.Children.Add(new TextBlock { Text = "Arrange turns adds any missing speaker bots to your meeting. Admit them from the lobby if needed.", TextWrapping = TextWrapping.Wrap });
            for (int i = 0; i < speakers.Count; i++)
            {
                int index = i; var speaker = speakers[i];
                var row = new StackPanel { Margin = new(0,10,0,8) };
                var name = new TextBox { Text = speaker.Name, Padding = new(5), MinHeight = 28, IsEnabled = speaker.Bot.Length == 0 };
                bool updatingName = false;
                name.TextChanged += (_, _) => {
                    if (updatingName) return;
                    speaker.Name = name.Text;
                    source.SaveRecallSpeakerConfiguration(templateId, speaker.Configuration);
                };
                name.LostFocus += (_, _) => { updatingName = true; name.Text = speaker.Name; updatingName = false; };
                row.Children.Add(new TextBlock { Text = $"Speaker {i + 1}" }); row.Children.Add(name);
                var voice = new ComboBox { ItemsSource = model.Voices, DisplayMemberPath = "DisplayName", SelectedValuePath = "Id", SelectedValue = speaker.Voice, Height = 24, Padding = new(6,1,6,1), Margin = new(0,6,0,0) };
                voice.SelectionChanged += (_, _) => {
                    if (voice.SelectedValue is not string value) return;
                    if (speaker.Bot.Length > 0 && speaker.Configuration.CustomName.Length == 0) speaker.Name = speaker.Name;
                    speaker.Voice = value;
                    speaker.Configuration.VoiceName = model.Voices.FirstOrDefault(v => v.Id == value)?.Name ?? "";
                    source.SaveRecallSpeakerConfiguration(templateId, speaker.Configuration);
                    updatingName = true; name.Text = speaker.Name; updatingName = false;
                };
                row.Children.Add(voice);
                var actions = new StackPanel { Orientation = Orientation.Horizontal };
                if (speaker.Bot.Length > 0) actions.Children.Add(Button("Remove bot", async () => {
                    await model.Recall.HandleAsync("remove", new() { ["botId"] = speaker.Bot });
                    speaker.Bot = ""; speaker.Status = "Not added";
                }));
                var status = new TextBlock { Text = speaker.Status, VerticalAlignment = VerticalAlignment.Center }; statuses[index] = status;
                actions.Children.Add(status); row.Children.Add(actions); body.Children.Add(row);
            }
            var footer = new WrapPanel();
            if (speakers.All(s => s.Bot.Length == 0)) footer.Children.Add(Button("Change meeting", () => { step = 0; return Task.CompletedTask; }));
            footer.Children.Add(Button("Refresh bots", Refresh));
            footer.Children.Add(RemoveAllBotsButton());

            footer.Children.Add(Button("Arrange turns", async () => {
                if (speakers.Any(s => string.IsNullOrWhiteSpace(s.Name) || string.IsNullOrWhiteSpace(s.Voice))) throw new AppException("Enter a name and choose a voice for every speaker.");
                foreach (var speaker in speakers.Where(s => s.Bot.Length == 0)) {
                    message.Text = "Adding " + speaker.Name + " to the meeting…";
                    var result = await model.Recall.HandleAsync("add", new() { ["meetingUrl"] = selectedMeeting, ["name"] = speaker.Name.Trim() });
                    speaker.Bot = result["bot"]!["id"]!.GetValue<string>();
                    speaker.Status = result["bot"]?["status"]?.GetValue<string>() ?? "Joining";
                }
                step = 2;
                message.Text = "Speaker bots have been sent to the meeting. Admit them from the lobby if needed.";
                await SafeRefresh();
            })); body.Children.Add(footer);
            return;
        }
        body.Children.Add(new TextBlock { Text = "All speech is prepared before playback. Turns then run with no added pause. Separate bots may still have small gaps or overlap because Recall does not confirm playback timing.", TextWrapping = TextWrapping.Wrap });
        for (int i = 0; i < speakers.Count; i++) {
            var status = new TextBlock { Text = speakers[i].Name + ": " + speakers[i].Status, Margin = new(0,2,0,2) };
            statuses[i] = status; body.Children.Add(status);
        }
        var buttons = new WrapPanel();
        buttons.Children.Add(Button("Back to bots", () => { step = 1; return Task.CompletedTask; }));
        buttons.Children.Add(RemoveAllBotsButton());
        buttons.Children.Add(Button("Add turn", () => { turns.Add(new(0,"Enter speech here.")); return Task.CompletedTask; }));
        buttons.Children.Add(Button("Start meeting", Start)); body.Children.Add(buttons);
        for (int i = 0; i < turns.Count; i++)
        {
            int index = i; var turn = turns[i];
            var row = new StackPanel { Margin = new(0,10,0,8) };
            var actions = new WrapPanel();
            actions.Children.Add(new TextBlock { Text = $"{i + 1}. ", VerticalAlignment = VerticalAlignment.Center });
            var speaker = new ComboBox { ItemsSource = speakers.Select(s => s.Name).ToArray(), SelectedIndex = turn.SpeakerIndex, MinWidth = 180, Height = 28, VerticalAlignment = VerticalAlignment.Center };
            speaker.SelectionChanged += (_, _) => { if (speaker.SelectedIndex >= 0) turns[index] = turns[index] with { SpeakerIndex = speaker.SelectedIndex }; };
            actions.Children.Add(speaker);
            if (i > 0) actions.Children.Add(Button("↑", () => { (turns[index-1],turns[index]) = (turns[index],turns[index-1]); return Task.CompletedTask; }));
            if (i < turns.Count-1) actions.Children.Add(Button("↓", () => { (turns[index+1],turns[index]) = (turns[index],turns[index+1]); return Task.CompletedTask; }));
            actions.Children.Add(Button("Remove turn", () => { turns.RemoveAt(index); return Task.CompletedTask; }));
            row.Children.Add(actions);
            var text = new TextBox { Text = Resolve(turn.Text), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 70, MaxHeight = 150, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new(5) };
            text.TextChanged += (_, _) => turns[index] = turns[index] with { Text = text.Text };
            row.Children.Add(text); body.Children.Add(row);
        }

    }
    private Button RemoveAllBotsButton()
    {
        var button = Button("Remove all bots", async () => {
            var failures = new List<string>();
            foreach (var speaker in speakers.Where(s => s.Bot.Length > 0)) {
                try {
                    await model.Recall.HandleAsync("remove", new() { ["botId"] = speaker.Bot });
                    speaker.Bot = ""; speaker.Status = "Not added";
                } catch (Exception error) { failures.Add(speaker.Name + ": " + error.Message); }
            }
            // Return to bot setup so a new run recreates removed speakers.
            step = 1;
            message.Text = failures.Count == 0 ? "All speaker bots removed." : "Some bots could not be removed. Retry Remove all bots.\n" + string.Join("\n", failures);
        });
        button.IsEnabled = !busy && run == null && speakers.Any(s => s.Bot.Length > 0);
        return button;
    }

    private string Resolve(string text) { for (int i=0; i<speakers.Count; i++) text = text.Replace($"{{{{speaker_{i+1}}}}}", speakers[i].Name); return text; }
    private async Task Refresh()
    {
        if (refreshing) return;
        refreshing = true;
        try {
            var result = await model.Recall.HandleAsync("list", new() { ["meetingId"] = selectedMeeting });
            foreach (var (speaker,index) in speakers.Select((s,i)=>(s,i))) {
                if (speaker.Bot.Length == 0) continue;
                var bot = result["bots"]!.AsArray().FirstOrDefault(b => b?["id"]?.GetValue<string>() == speaker.Bot);
                speaker.Status = bot?["status"]?.GetValue<string>() ?? "Unavailable";
                if (statuses.TryGetValue(index, out var label)) label.Text = step == 2 ? speaker.Name + ": " + speaker.Status : speaker.Status;
            }
        } finally { refreshing = false; }
    }
    private async Task SafeRefresh() { try { await Refresh(); } catch (Exception error) { message.Text = error.Message; } }
    private async Task Start()
    {
        if (turns.Count == 0 || turns.Any(t => string.IsNullOrWhiteSpace(t.Text))) throw new AppException("Add nonempty speech for each turn.");
        await Refresh();
        if (speakers.Any(s => s.Status != "in_call_recording")) throw new AppException("Wait until every speaker bot is in_call_recording. Admit bots from the lobby if needed.");
        run = new();
        body.Children.Clear(); body.IsEnabled = true;
        var stop = new Button { Content = "Stop meeting", Padding = new(12,5,12,5), HorizontalAlignment = HorizontalAlignment.Left };
        bool skipRequested = false;
        var skip = new Button { Content = "Skip turn", Padding = new(12,5,12,5), Margin = new(0,0,8,0) };
        skip.IsEnabled = false;
        skip.Click += (_, _) => { skipRequested = true; skip.IsEnabled = false; };
        stop.Click += (_, _) => { run?.Cancel(); stop.IsEnabled = false; skip.IsEnabled = false; };
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        actions.Children.Add(skip); actions.Children.Add(stop); body.Children.Add(actions);
        body.Children.Add(new TextBlock { Text = "Skip advances to the next turn. Audio already sent may finish playing over the next speaker.", TextWrapping = TextWrapping.Wrap, Margin = new(0,8,0,0) });
        try {
            var plan = turns.Select(t => new RecallMeetingTurn(speakers[t.SpeakerIndex].Bot, speakers[t.SpeakerIndex].Voice, Resolve(t.Text))).ToArray();
            await RecallTurnRunner.RunAsync(plan, model.Recall.HandleAsync, index => {
                skipRequested = false; skip.IsEnabled = true;
                message.Text = $"Turn {index+1} of {plan.Length} · {speakers[turns[index].SpeakerIndex].Name}\n\n{plan[index].Text}";
            }, run.Token, () => skipRequested, index => {
                message.Text = $"Preparing speech {index+1} of {plan.Length} before playback…";
            });
            message.Text = "All turns dispatched. Use Remove all bots to disconnect the speaker bots from the meeting.";
        }
        catch (OperationCanceledException) { message.Text = "Stopped. Audio already sent may finish playing. Use Remove all bots to disconnect the speaker bots from the meeting."; }
        finally { run.Dispose(); run = null; }
    }
}
