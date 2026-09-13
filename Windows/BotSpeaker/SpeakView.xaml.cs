using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace BotSpeaker;

/// <summary>
/// Type text and play it on this PC or, while hosting, on any paired
/// attendee. The <c>botspeaker-cli</c> drives the same queue, so requests
/// from either source show up in the recent list.
/// </summary>
public partial class SpeakView : UserControl
{
    private const string LocalTargetId = SpeechRequest.LocalTarget;

    private readonly AppModel _model;
    private readonly OrchestrationController _orchestration;
    private readonly bool _compact;
    private string _targetId = LocalTargetId;
    private string _voiceId = "";
    private bool _isSubmitting;
    private string? _errorMessage;
    private bool _suppressUiEvents;

    private static readonly Brush QueuedBrush = Brushes.Gray;
    private static readonly Brush PreparingBrush = Brushes.Orange;
    private static readonly Brush SpeakingBrush = Brushes.LimeGreen;
    private static readonly Brush CompletedBrush = new SolidColorBrush(Color.FromRgb(0x2E, 0x6B, 0xD6));
    private static readonly Brush FailedBrush = Brushes.Red;
    private static readonly Brush CancelledBrush = Brushes.DarkGray;

    /// <param name="compact">Fits the attendee session view: a shorter box and fewer recent rows.</param>
    public SpeakView(AppModel model, OrchestrationController orchestration, bool compact = false)
    {
        _model = model;
        _orchestration = orchestration;
        _compact = compact;
        InitializeComponent();

        if (compact)
        {
            SpeechTextBox.MinHeight = 72;
            SpeechTextBox.MaxHeight = 120;
            RecentTitle.Text = "RECENT";
        }

        _model.PropertyChanged += OnStateChanged;
        _orchestration.PropertyChanged += OnStateChanged;
        Loaded += async (_, _) =>
        {
            UpdateAll();
            if (_model.HasApiKey) await _model.LoadVoicesIfNeededAsync();
        };
    }

    private void OnStateChanged(object? sender, PropertyChangedEventArgs e) =>
        Dispatcher.BeginInvoke(UpdateAll);

    /// <summary>Puts the keyboard focus in the text box.</summary>
    public void FocusText() => SpeechTextBox.Focus();

    private bool CanTargetAttendees => _orchestration.IsHost;

    private List<OrchestrationParticipant> Attendees => CanTargetAttendees
        ? _orchestration.Participants.Where(p => p.Id != _orchestration.LocalParticipantId).ToList()
        : [];

    private OrchestrationParticipant? SelectedAttendee => Attendees.FirstOrDefault(p => p.Id == _targetId);

    private List<SpeechRequest> Requests
    {
        get
        {
            int limit = _compact ? 4 : 12;
            var all = _orchestration.SpeechRequests;
            return all.Skip(Math.Max(all.Count - limit, 0)).Reverse().ToList();
        }
    }

    private void UpdateAll()
    {
        _suppressUiEvents = true;
        try
        {
            var attendees = Attendees;
            if (_targetId != LocalTargetId && attendees.All(a => a.Id != _targetId))
            {
                _targetId = LocalTargetId;
            }

            TargetRow.Visibility = CanTargetAttendees ? Visibility.Visible : Visibility.Collapsed;
            if (CanTargetAttendees)
            {
                var entries = new List<string> { "This PC" };
                entries.AddRange(attendees.Select(a =>
                    a.IsRecentlyConnected ? a.DisplayName : $"{a.DisplayName} (offline)"));
                TargetCombo.ItemsSource = entries;
                int index = attendees.FindIndex(a => a.Id == _targetId);
                TargetCombo.SelectedIndex = index < 0 ? 0 : index + 1;
                TargetHint.Text = attendees.Count == 0
                    ? $"No attendees paired yet · share code {_orchestration.PairingCode}"
                    : "";
            }

            var voices = _model.Voices;
            if (_model.IsLoadingVoices)
            {
                VoiceCombo.ItemsSource = new List<string> { "Loading ElevenLabs voices…" };
                VoiceCombo.SelectedIndex = 0;
                VoiceCombo.IsEnabled = false;
            }
            else
            {
                if (_voiceId.Length > 0 && voices.All(v => v.Id != _voiceId)) _voiceId = "";
                var entries = new List<string> { DefaultVoiceLabel };
                entries.AddRange(voices.Select(v => v.DisplayName));
                VoiceCombo.ItemsSource = entries;
                int index = voices.FindIndex(v => v.Id == _voiceId);
                VoiceCombo.SelectedIndex = index < 0 ? 0 : index + 1;
                VoiceCombo.IsEnabled = true;
            }

            StopAllButton.Visibility = _orchestration.HasPendingSpeech ? Visibility.Visible : Visibility.Collapsed;
            var attendee = SelectedAttendee;
            SpeakSubmitButton.Content = _isSubmitting
                ? "Queuing…"
                : attendee is null ? "▶ Speak" : $"📡 Speak on {attendee.DisplayName}";
            SpeakSubmitButton.IsEnabled = !_isSubmitting && SpeechTextBox.Text.Trim().Length > 0;

            if (_errorMessage is string error)
            {
                StatusText.Text = "⚠ " + error;
                StatusText.Foreground = Brushes.Red;
            }
            else
            {
                int words = SpeechTextBox.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
                StatusText.Text = LoopCheck.IsChecked == true
                    ? $"{words} words · loops until stopped · Ctrl+Enter to speak"
                    : $"{words} words · Ctrl+Enter to speak";
                StatusText.Foreground = Brushes.Gray;
            }

            RebuildRecentList();
        }
        finally
        {
            _suppressUiEvents = false;
        }
    }

    private string DefaultVoiceLabel =>
        SelectedAttendee is null ? $"Default ({_model.SelectedVoiceName})" : "Attendee's own voice";

    private void RebuildRecentList()
    {
        var requests = Requests;
        RecentPanel.Visibility = requests.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        RecentList.Children.Clear();
        foreach (var request in requests)
        {
            RecentList.Children.Add(BuildRequestRow(request));
        }
    }

    private DockPanel BuildRequestRow(SpeechRequest request)
    {
        var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };

        var dot = new System.Windows.Shapes.Ellipse
        {
            Width = 8,
            Height = 8,
            Fill = StatusBrush(request.Status),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 5, 8, 0),
        };
        DockPanel.SetDock(dot, Dock.Left);
        row.Children.Add(dot);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
        if (!request.Status.IsTerminal())
        {
            var cancel = new Button
            {
                Content = "✕",
                Style = (Style)FindResource("IconButton"),
                ToolTip = "Cancel",
                FontSize = 12,
            };
            string id = request.Id;
            cancel.Click += async (_, _) =>
            {
                try { await _orchestration.CancelSpeechAsync(id); } catch (AppException) { }
            };
            buttons.Children.Add(cancel);
        }
        var reuse = new Button
        {
            Content = "⧉",
            Style = (Style)FindResource("IconButton"),
            ToolTip = "Copy this request's text, voice, and target into the box above",
            FontSize = 13,
        };
        reuse.Click += (_, _) => RequestReuse(request);
        buttons.Children.Add(reuse);
        DockPanel.SetDock(buttons, Dock.Right);
        row.Children.Add(buttons);

        var text = new StackPanel();
        text.Children.Add(new TextBlock
        {
            Text = request.Text.ReplaceLineEndings(" "),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        text.Children.Add(new TextBlock
        {
            Text = RequestDetail(request),
            FontSize = 11,
            Foreground = request.Status == SpeechRequestStatus.Failed ? Brushes.Red : Brushes.Gray,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        row.Children.Add(text);
        return row;
    }

    private static string RequestDetail(SpeechRequest request)
    {
        var parts = new List<string> { request.TargetName, StatusName(request.Status) };
        if (request.IsLooping)
        {
            parts.Add($"pass {request.CompletedCycles}/{(request.Cycles is int cycles ? cycles.ToString() : "∞")}");
        }
        if (!string.IsNullOrEmpty(request.VoiceName)) parts.Add(request.VoiceName);
        if (request.Error is string error) parts.Add(error);
        return string.Join(" · ", parts);
    }

    private static string StatusName(SpeechRequestStatus status) => status switch
    {
        SpeechRequestStatus.Queued => "Queued",
        SpeechRequestStatus.Preparing => "Preparing",
        SpeechRequestStatus.Speaking => "Speaking",
        SpeechRequestStatus.Completed => "Completed",
        SpeechRequestStatus.Failed => "Failed",
        SpeechRequestStatus.Cancelled => "Cancelled",
        _ => "Queued",
    };

    private static Brush StatusBrush(SpeechRequestStatus status) => status switch
    {
        SpeechRequestStatus.Queued => QueuedBrush,
        SpeechRequestStatus.Preparing => PreparingBrush,
        SpeechRequestStatus.Speaking => SpeakingBrush,
        SpeechRequestStatus.Completed => CompletedBrush,
        SpeechRequestStatus.Failed => FailedBrush,
        SpeechRequestStatus.Cancelled => CancelledBrush,
        _ => QueuedBrush,
    };

    /// <summary>
    /// Copies a recent request back into the composer, asking first when it
    /// would discard text the user has typed.
    /// </summary>
    private void RequestReuse(SpeechRequest request)
    {
        if (SpeechTextBox.Text.Trim().Length > 0)
        {
            var confirmation = MessageBox.Show(
                Window.GetWindow(this),
                "The text you have typed will be replaced with the selected request's text, voice, and target.",
                "Replace the current text?",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question,
                MessageBoxResult.No);
            if (confirmation != MessageBoxResult.Yes) return;
        }
        Reuse(request);
    }

    private void Reuse(SpeechRequest request)
    {
        _errorMessage = null;
        _voiceId = request.VoiceId ?? "";
        _targetId = request.IsRemote && CanTargetAttendees && Attendees.Any(a => a.Id == request.TargetUid)
            ? request.TargetUid
            : LocalTargetId;
        _suppressUiEvents = true;
        try
        {
            LoopCheck.IsChecked = request.IsLooping;
            SpeechTextBox.Text = request.Text;
        }
        finally
        {
            _suppressUiEvents = false;
        }
        UpdateAll();
        SpeechTextBox.Focus();
        SpeechTextBox.CaretIndex = SpeechTextBox.Text.Length;
    }

    private async Task SubmitAsync()
    {
        var text = SpeechTextBox.Text;
        if (_isSubmitting || text.Trim().Length == 0) return;
        var target = _targetId;
        var voiceId = _voiceId.Length == 0 ? null : _voiceId;
        int? cycles = LoopCheck.IsChecked == true ? null : 1;
        _isSubmitting = true;
        _errorMessage = null;
        UpdateAll();
        try
        {
            await _orchestration.SpeakAsync(text, target, voiceId, cycles);
            SpeechTextBox.Clear();
        }
        catch (Exception error)
        {
            _errorMessage = error.Message;
        }
        finally
        {
            _isSubmitting = false;
            UpdateAll();
        }
    }

    // Event handlers

    private void OnTargetChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressUiEvents) return;
        int index = TargetCombo.SelectedIndex;
        var attendees = Attendees;
        _targetId = index >= 1 && index - 1 < attendees.Count ? attendees[index - 1].Id : LocalTargetId;
        UpdateAll();
    }

    private void OnVoiceChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressUiEvents || _model.IsLoadingVoices) return;
        int index = VoiceCombo.SelectedIndex;
        var voices = _model.Voices;
        _voiceId = index >= 1 && index - 1 < voices.Count ? voices[index - 1].Id : "";
    }

    private void OnLoopChanged(object sender, RoutedEventArgs e)
    {
        if (_suppressUiEvents) return;
        UpdateAll();
    }

    private void OnTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_suppressUiEvents) return;
        _errorMessage = null;
        UpdateAll();
    }

    private async void OnTextKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || (Keyboard.Modifiers & ModifierKeys.Control) == 0) return;
        e.Handled = true;
        await SubmitAsync();
    }

    private async void OnSpeakClick(object sender, RoutedEventArgs e) => await SubmitAsync();

    private async void OnStopAllClick(object sender, RoutedEventArgs e) => await _orchestration.CancelAllSpeechAsync();
}
