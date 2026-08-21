using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace BotSpeaker;

public partial class OrchestrationWindow : Window
{
    private readonly AppModel _model;
    private readonly OrchestrationController _controller;

    public OrchestrationWindow(AppModel model, OrchestrationController controller)
    {
        _model = model;
        _controller = controller;
        InitializeComponent();

        _controller.PropertyChanged += OnStateChanged;
        _model.PropertyChanged += OnStateChanged;
        _model.Player.PropertyChanged += OnStateChanged;

        Loaded += async (_, _) =>
        {
            UpdateAll();
            if (_model.HasApiKey) await _model.LoadVoicesIfNeededAsync();
        };
        Closing += OnWindowClosing;
        PreviewKeyDown += OnWindowPreviewKeyDown;
    }

    private async void OnWindowClosing(object? sender, CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
        if (_controller.IsActive)
        {
            await _controller.LeaveSessionAsync();
        }
    }

    private void OnStateChanged(object? sender, PropertyChangedEventArgs e) =>
        Dispatcher.BeginInvoke(UpdateAll);

    private async void OnWindowPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Space || !_controller.IsHost) return;
        if (_controller.SessionStatus == OrchestrationSessionStatus.Running)
        {
            e.Handled = true;
            await _controller.PauseMeetingAsync();
        }
        else if (_controller.SessionStatus == OrchestrationSessionStatus.Paused)
        {
            e.Handled = true;
            await _controller.ResumeMeetingAsync();
        }
    }

    private void UpdateAll()
    {
        bool active = _controller.IsActive;
        HostPanel.Visibility = active && _controller.IsHost ? Visibility.Visible : Visibility.Collapsed;
        RemotePanel.Visibility = active && !_controller.IsHost ? Visibility.Visible : Visibility.Collapsed;

        StatusPill.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        StatusPillText.Text = _controller.SessionStatus.DisplayName();

        if (_controller.IsHost)
        {
            UpdateHostSession();
        }
        else if (active)
        {
            UpdateRemoteSession();
        }
    }

    private void UpdateHostSession()
    {
        SpeakerMappingText.Text =
            $"Reorder paired clients to assign {string.Join(", ", _controller.SpeakerConfigurations.Select(
                configuration => string.IsNullOrWhiteSpace(configuration.Name)
                    ? $"Speaker {configuration.Slot}"
                    : configuration.Name.Trim()))}.";
        PairingCodeText.Text = _controller.PairingCode;
        if (MeetingScriptBox.Text != _controller.ConfiguredScriptPreview)
        {
            MeetingScriptBox.Text = _controller.ConfiguredScriptPreview;
        }
        MeetingScriptBox.IsReadOnly = true;
        PlanStateText.Text = _controller.Turns.Count == 0 ? "Draft" : "Prepared";

        RebuildSpeakersList();
        RebuildTimeline();

        HostErrorText.Text = _controller.ErrorMessage ?? "";
        HostErrorText.Visibility = _controller.ErrorMessage is null ? Visibility.Collapsed : Visibility.Visible;

        var status = _controller.SessionStatus;
        ExportButton.Visibility = _controller.CanExportTranscript ? Visibility.Visible : Visibility.Collapsed;
        PrepareButton.Visibility = status == OrchestrationSessionStatus.Lobby && _controller.Turns.Count == 0
            ? Visibility.Visible
            : Visibility.Collapsed;
        PrepareButton.IsEnabled = _controller.CanPrepareMeeting;
        StartButton.Visibility = status == OrchestrationSessionStatus.Lobby && _controller.Turns.Count > 0
            ? Visibility.Visible
            : Visibility.Collapsed;
        StartButton.IsEnabled = _controller.CanStartMeeting;
        SkipButton.Visibility = status is OrchestrationSessionStatus.Running or OrchestrationSessionStatus.Paused
            ? Visibility.Visible
            : Visibility.Collapsed;
        PauseButton.Visibility = status == OrchestrationSessionStatus.Running ? Visibility.Visible : Visibility.Collapsed;
        ResumeButton.Visibility = status == OrchestrationSessionStatus.Paused ? Visibility.Visible : Visibility.Collapsed;
        StopButton.Visibility = status is OrchestrationSessionStatus.Running or OrchestrationSessionStatus.Paused
            ? Visibility.Visible
            : Visibility.Collapsed;
        DoneButton.Visibility = status is OrchestrationSessionStatus.Completed or OrchestrationSessionStatus.Stopped
            ? Visibility.Visible
            : Visibility.Collapsed;
        LeaveButton.Visibility = DoneButton.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
    }

    private void RebuildSpeakersList()
    {
        var byId = _controller.Participants.ToDictionary(p => p.Id);
        var ordered = _controller.ParticipantOrder
            .Where(byId.ContainsKey)
            .Select(id => byId[id])
            .ToList();
        bool lobby = _controller.SessionStatus == OrchestrationSessionStatus.Lobby;
        var activeUid = _controller.ActiveTurn?.ParticipantUid;

        SpeakersList.Children.Clear();
        for (int index = 0; index < ordered.Count; index++)
        {
            var participant = ordered[index];
            var row = new DockPanel { Margin = new Thickness(2) };

            if (lobby && _controller.Turns.Count == 0)
            {
                var buttons = new StackPanel { Orientation = Orientation.Horizontal };
                var up = new Button { Content = "▲", FontSize = 9, Padding = new Thickness(5, 2, 5, 2), IsEnabled = index > 0 };
                var id = participant.Id;
                up.Click += (_, _) => _controller.MoveParticipant(id, -1);
                var down = new Button
                {
                    Content = "▼",
                    FontSize = 9,
                    Padding = new Thickness(5, 2, 5, 2),
                    Margin = new Thickness(4, 0, 0, 0),
                    IsEnabled = index < ordered.Count - 1,
                };
                down.Click += (_, _) => _controller.MoveParticipant(id, 1);
                buttons.Children.Add(up);
                buttons.Children.Add(down);
                DockPanel.SetDock(buttons, Dock.Right);
                row.Children.Add(buttons);
            }

            var dot = new System.Windows.Shapes.Ellipse
            {
                Width = 8,
                Height = 8,
                Fill = participant.IsRecentlyConnected ? Brushes.LimeGreen : Brushes.Orange,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(4, 0, 8, 0),
            };
            DockPanel.SetDock(dot, Dock.Left);
            row.Children.Add(dot);

            var textPanel = new StackPanel();
            textPanel.Children.Add(new TextBlock
            {
                Text = participant.DisplayName,
                FontWeight = FontWeights.SemiBold,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            textPanel.Children.Add(new TextBlock
            {
                Text = index < _controller.SelectedTemplate.SpeakerRoles.Count
                    ? $"{ConfiguredSpeakerName(index)} · {_controller.SelectedTemplate.SpeakerRoles[index]} · {participant.SegmentCount} turns"
                    : $"Unassigned client · {participant.VoiceName}",
                FontSize = 11,
                Foreground = Brushes.Gray,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            string preparationText = !string.IsNullOrEmpty(participant.PreparationError)
                ? $"Preparation failed: {participant.PreparationError}"
                : participant.SegmentCount > 0
                    ? $"{participant.PreparedSegmentCount} of {participant.SegmentCount} prepared"
                    : "Waiting for script assignment";
            textPanel.Children.Add(new TextBlock
            {
                Text = preparationText,
                FontSize = 10,
                Foreground = !string.IsNullOrEmpty(participant.PreparationError)
                    ? Brushes.Red
                    : participant.SegmentCount > 0 && participant.PreparedSegmentCount == participant.SegmentCount
                        ? Brushes.Green
                        : Brushes.Gray,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            row.Children.Add(textPanel);

            SpeakersList.Children.Add(new Border
            {
                Child = row,
                Padding = new Thickness(7),
                CornerRadius = new CornerRadius(6),
                Background = participant.Id == activeUid
                    ? new SolidColorBrush(Color.FromArgb(0x24, 0x2E, 0x6B, 0xD6))
                    : Brushes.Transparent,
            });
        }
    }

    private string ConfiguredSpeakerName(int index)
    {
        if (index < 0 || index >= _controller.SpeakerConfigurations.Count) return $"Speaker {index + 1}";
        var name = _controller.SpeakerConfigurations[index].Name.Trim();
        return name.Length == 0 ? $"Speaker {index + 1}" : name;
    }

    private void RebuildTimeline()
    {
        var turns = _controller.Turns;
        var activeTurn = _controller.ActiveTurn;

        bool showNow = activeTurn is not null && _controller.SessionStatus != OrchestrationSessionStatus.Completed;
        NowSpeakingText.Visibility = showNow ? Visibility.Visible : Visibility.Collapsed;
        NowSpeakingDetail.Visibility = showNow ? Visibility.Visible : Visibility.Collapsed;
        if (showNow)
        {
            NowSpeakingText.Text = $"Now: {activeTurn!.SpeakerName}";
            NowSpeakingDetail.Text =
                $"Turn {activeTurn.Index + 1} of {turns.Count} · paragraph {activeTurn.SegmentIndex + 1}";
        }

        TimelineEmptyText.Visibility = turns.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        TurnProgress.Visibility = turns.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (turns.Count > 0)
        {
            TurnProgress.Maximum = turns.Count;
            TurnProgress.Value = Math.Max(_controller.ActiveTurnIndex, 0);
        }

        TimelineList.Children.Clear();
        foreach (var turn in turns)
        {
            var row = new DockPanel { Margin = new Thickness(2, 2, 2, 2) };
            var statusText = new TextBlock
            {
                Text = Capitalize(turn.Status.RawValue()),
                FontSize = 11,
                Foreground = Brushes.Gray,
                VerticalAlignment = VerticalAlignment.Center,
            };
            DockPanel.SetDock(statusText, Dock.Right);
            row.Children.Add(statusText);

            var icon = new TextBlock
            {
                Text = TurnIcon(turn.Status),
                Width = 20,
                Foreground = TurnBrush(turn.Status),
                VerticalAlignment = VerticalAlignment.Center,
            };
            DockPanel.SetDock(icon, Dock.Left);
            row.Children.Add(icon);

            row.Children.Add(new TextBlock
            {
                Text = $"{turn.Index + 1}. {turn.SpeakerName}",
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            });
            TimelineList.Children.Add(row);
        }
    }

    private void UpdateRemoteSession()
    {
        RemoteStatusIcon.Text = _controller.SessionStatus switch
        {
            OrchestrationSessionStatus.Lobby => "⏳",
            OrchestrationSessionStatus.Running => _model.Player.IsPlaying ? "🔊" : "📡",
            OrchestrationSessionStatus.Paused => "⏸",
            OrchestrationSessionStatus.Completed => "✅",
            OrchestrationSessionStatus.Stopped => "⏹",
            _ => "⏳",
        };
        RemoteStatusTitle.Text = _controller.SessionStatus.DisplayName();
        RemoteStatusDetail.Text = _model.RemoteControlStatus;

        RemoteRoomText.Text = _controller.PairingCode;
        RemoteSpeakerText.Text = _controller.SpeakerName;
        RemoteScriptText.Text = _controller.MeetingScriptTitle;
        RemoteVoiceText.Text = _model.SelectedVoiceName;
        RemoteTurnsText.Text = $"{_controller.PreparedLocalSegmentCount} of {_controller.LocalAssignedSegmentCount}";

        if (_controller.ActiveTurn is OrchestrationTurn turn)
        {
            RemoteCurrentTurnText.Text =
                $"Current meeting turn: {turn.Index + 1} of {_controller.Turns.Count} — {turn.SpeakerName}";
            RemoteCurrentTurnText.Visibility = Visibility.Visible;
        }
        else
        {
            RemoteCurrentTurnText.Visibility = Visibility.Collapsed;
        }

        var remoteError = _controller.ErrorMessage ?? _controller.PreparationError;
        RemoteErrorText.Text = remoteError ?? "";
        RemoteErrorText.Visibility = remoteError is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private static string TurnIcon(OrchestrationTurnStatus status) => status switch
    {
        OrchestrationTurnStatus.Completed => "✔",
        OrchestrationTurnStatus.Speaking => "🔊",
        OrchestrationTurnStatus.Preparing => "…",
        OrchestrationTurnStatus.Assigned => "▶",
        OrchestrationTurnStatus.Paused => "⏸",
        OrchestrationTurnStatus.Failed => "⚠",
        OrchestrationTurnStatus.Skipped or OrchestrationTurnStatus.Stopped => "⏭",
        _ => "○",
    };

    private static Brush TurnBrush(OrchestrationTurnStatus status) => status switch
    {
        OrchestrationTurnStatus.Completed => Brushes.Green,
        OrchestrationTurnStatus.Speaking => new SolidColorBrush(Color.FromRgb(0x2E, 0x6B, 0xD6)),
        OrchestrationTurnStatus.Failed => Brushes.Red,
        OrchestrationTurnStatus.Skipped or OrchestrationTurnStatus.Stopped => Brushes.DarkOrange,
        _ => Brushes.Gray,
    };

    private static string Capitalize(string value) =>
        value.Length == 0 ? value : char.ToUpperInvariant(value[0]) + value[1..];

    // Event handlers

    private void OnCopyPairingCodeClick(object sender, RoutedEventArgs e)
    {
        try
        {
            Clipboard.SetText(_controller.PairingCode);
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            // Another process briefly held the clipboard; the user can retry.
        }
    }

    private async void OnStartClick(object sender, RoutedEventArgs e) => await _controller.StartMeetingAsync();

    private async void OnPrepareClick(object sender, RoutedEventArgs e) => await _controller.PrepareMeetingAsync();

    private async void OnPauseClick(object sender, RoutedEventArgs e) => await _controller.PauseMeetingAsync();

    private async void OnResumeClick(object sender, RoutedEventArgs e) => await _controller.ResumeMeetingAsync();

    private async void OnSkipClick(object sender, RoutedEventArgs e) => await _controller.SkipCurrentTurnAsync();

    private async void OnStopClick(object sender, RoutedEventArgs e) => await _controller.StopMeetingAsync();

    private async void OnLeaveClick(object sender, RoutedEventArgs e) => await _controller.LeaveSessionAsync();

    private void OnExportClick(object sender, RoutedEventArgs e)
    {
        try
        {
            _controller.ExportTranscript();
        }
        catch (Exception error)
        {
            HostErrorText.Text = error.Message;
            HostErrorText.Visibility = Visibility.Visible;
        }
    }
}
