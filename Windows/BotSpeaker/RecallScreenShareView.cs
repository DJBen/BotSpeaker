using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace BotSpeaker;

/// <summary>Always usable during meeting speech; UI and CLI share the same controller state.</summary>
public sealed class RecallScreenShareView : GroupBox
{
    public sealed record Bot(string Id, string Name, string Status);
    private readonly RecallController controller;
    private readonly Func<Bot[]> source;
    private readonly ComboBox selection = new() { DisplayMemberPath = "Name", SelectedValuePath = "Id", MinWidth = 200 };
    private readonly Button start = new() { Content = "Share test screen", Padding = new(12,5,12,5), Margin = new(0,8,8,8) };
    private readonly Button stop = new() { Content = "Stop sharing", Padding = new(12,5,12,5), Margin = new(0,8,8,8) };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private Bot[] bots = [];
    private bool busy;

    public RecallScreenShareView(RecallController controller, Func<Bot[]> source)
    {
        this.controller = controller; this.source = source;
        Header = "Screen share"; Margin = new(0,8,0,8);
        var panel = new StackPanel { Margin = new(8) }; Content = panel;
        panel.Children.Add(new TextBlock { Text = "Presenting bot", Margin = new(0,0,0,4) });
        System.Windows.Automation.AutomationProperties.SetName(selection, "Presenting bot");
        panel.Children.Add(selection);
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        actions.Children.Add(start); actions.Children.Add(stop); panel.Children.Add(actions); panel.Children.Add(status);
        panel.Children.Add(new TextBlock { Text = "Shows a test card from a remote bot. Sharing works independently of speech. Check the meeting to confirm it is visible; the host must allow this bot to present.", TextWrapping = TextWrapping.Wrap, Margin = new(0,6,0,0) });
        selection.SelectionChanged += (_, _) => RefreshButtons();
        start.Click += async (_, _) => await Request("screenshare-start");
        stop.Click += async (_, _) => await Request("screenshare-stop");
        timer.Tick += (_, _) => Refresh();
        Loaded += (_, _) => { Refresh(); timer.Start(); };
        Unloaded += (_, _) => timer.Stop();
    }
    private void Refresh()
    {
        var current = source();
        if (!current.SequenceEqual(bots)) {
            var selected = selection.SelectedValue?.ToString();
            bots = current; selection.ItemsSource = bots; selection.SelectedValue = selected;
            if (selection.SelectedIndex < 0 && bots.Length > 0) selection.SelectedIndex = 0;
        }
        RefreshButtons();
    }
    private void RefreshButtons()
    {
        var bot = selection.SelectedItem as Bot;
        var share = bot == null ? null : controller.ScreenShare(bot.Id);
        var state = share?["state"]?.GetValue<string>() ?? "";
        var pending = busy || state is "starting" or "stopping";
        start.IsEnabled = !pending && (bot?.Status is "in_call_recording" or "in_call_not_recording");
        stop.IsEnabled = !pending && bot != null;
        status.Text = share?["error"]?.GetValue<string>() ?? state.Replace('_', ' ');
    }
    private async Task Request(string action)
    {
        if (busy || selection.SelectedItem is not Bot bot) return;
        busy = true; RefreshButtons();
        try { await controller.HandleAsync(action, new() { ["botId"] = bot.Id }); }
        catch (Exception error) { status.Text = error.Message; }
        finally { busy = false; RefreshButtons(); }
    }
}
