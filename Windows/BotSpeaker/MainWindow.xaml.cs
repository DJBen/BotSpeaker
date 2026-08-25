using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Navigation;
using System.Windows.Threading;

namespace BotSpeaker;

public partial class MainWindow : Window
{
    private readonly AppModel _model;
    private readonly OrchestrationController _orchestration;
    private bool _showOrchestrationConfiguration;
    private bool _showRemoteMode;
    private bool _showOrchestrationSession;
    private bool _isScrubbing;
    private bool _suppressUiEvents;
    private ScriptEditorWindow? _scriptEditor;
    private SettingsWindow? _settingsWindow;
    private readonly OrchestrationView _orchestrationView;

    private static readonly Brush SpokenBrush = new SolidColorBrush(Color.FromArgb(0x59, 0x34, 0xC7, 0x59));
    private static readonly Brush SpeakingBrush = new SolidColorBrush(Color.FromArgb(0x8C, 0x2E, 0x6B, 0xD6));

    private string _renderedText = "";
    private int _renderedPlayed = -1;
    private TextSpan? _renderedActive;
    private Run? _renderedActiveRun;
    private ScrollViewer? _scriptScroller;

    public MainWindow(AppModel model, OrchestrationController orchestration)
    {
        _model = model;
        _orchestration = orchestration;
        InitializeComponent();

        _model.PropertyChanged += OnModelChanged;
        _model.Player.PropertyChanged += OnPlayerChanged;
        _orchestration.PropertyChanged += OnModelChanged;

        // The meeting session lives in this window, replacing the detail pane
        // rather than opening a second window.
        _orchestrationView = new OrchestrationView(model, orchestration);
        _orchestrationView.SettingsRequested += (_, _) => OnSettingsClick(this, new RoutedEventArgs());
        _orchestrationView.MeetingViewDismissRequested += (_, _) =>
        {
            _showRemoteMode = false;
            _showOrchestrationSession = false;
            _showOrchestrationConfiguration = false;
            UpdateAll();
        };
        _orchestrationView.ChooseAnotherScriptRequested += (_, _) =>
        {
            _showRemoteMode = false;
            _showOrchestrationSession = false;
            _showOrchestrationConfiguration = true;
            UpdateAll();
        };
        OrchestrationSessionHost.Content = _orchestrationView;

        Loaded += async (_, _) =>
        {
            UpdateAll();
            if (_model.HasApiKey) await _model.LoadVoicesIfNeededAsync();
            await _orchestration.RestorePersistedSessionIfNeededAsync();
            if (_orchestration.ActiveMode == OrchestrationMode.Remote)
            {
                _showRemoteMode = true;
                _showOrchestrationSession = true;
            }
            UpdateAll();
        };
        Closing += OnWindowClosing;
        PreviewKeyDown += OnWindowPreviewKeyDown;
    }

    private async void OnWindowPreviewKeyDown(object sender, KeyEventArgs e)
    {
        // Space toggles play/pause while the window is foregrounded, unless the user
        // is typing in an editable field or operating a control that consumes space.
        if (e.Key != Key.Space || !_model.HasApiKey) return;
        if (_orchestration.IsActive)
        {
            e.Handled = _orchestrationView.HandleSpaceShortcut();
            return;
        }
        if (_model.IsRemoteControlled) return;
        if (!_model.SelectedScript.IsCustom) return;
        var focused = Keyboard.FocusedElement;
        if (focused is PasswordBox) return;
        if (focused is TextBoxBase editable && !editable.IsReadOnly) return;
        // A closed ComboBox keeps focus after a selection; only yield space to it
        // while its dropdown is open.
        if (focused is ComboBox combo && combo.IsDropDownOpen) return;
        if (focused is ComboBoxItem) return;
        if (!PlayButton.IsEnabled) return;
        e.Handled = true;
        await _model.PrimaryActionAsync();
    }

    private void OnWindowClosing(object? sender, CancelEventArgs e)
    {
        // Behave like the macOS menu-bar app: closing the window keeps the app in the tray.
        e.Cancel = true;
        Hide();
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) =>
        Dispatcher.BeginInvoke(UpdateAll);

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs e) =>
        Dispatcher.BeginInvoke(UpdatePlayback);

    private void UpdateAll()
    {
        _suppressUiEvents = true;
        try
        {
            FirstRunPanel.Visibility = _model.HasApiKey ? Visibility.Collapsed : Visibility.Visible;
            bool inSession = _orchestration.IsActive;
            bool hostCanChooseRun = _orchestration.IsHost
                && ((_orchestration.SessionStatus == OrchestrationSessionStatus.Lobby && _orchestration.Turns.Count == 0)
                    || _orchestration.SessionStatus is OrchestrationSessionStatus.Completed or OrchestrationSessionStatus.Stopped);
            bool choosingNextHostScript = _showOrchestrationConfiguration
                && hostCanChooseRun;
            bool showSession = inSession && _showOrchestrationSession && !choosingNextHostScript;
            ComposerPanel.Visibility = _showOrchestrationConfiguration || _showRemoteMode || showSession
                ? Visibility.Collapsed
                : Visibility.Visible;
            OrchestrationConfigurationPanel.Visibility = _showOrchestrationConfiguration && (!inSession || choosingNextHostScript)
                ? Visibility.Visible
                : Visibility.Collapsed;
            OrchestrationSessionHost.Visibility = showSession ? Visibility.Visible : Visibility.Collapsed;
            RemoteModePanel.Visibility = _showRemoteMode && !inSession
                ? Visibility.Visible
                : Visibility.Collapsed;
            RemoteSpeakerNameBox.Text = _orchestration.SpeakerName;
            HostMeetingButton.Visibility = inSession ? Visibility.Collapsed : Visibility.Visible;
            HostMeetingButton.IsEnabled = !_orchestration.IsBusy;
            bool isHosting = _orchestration.IsHost;
            AttendeeListButton.Visibility = isHosting ? Visibility.Visible : Visibility.Collapsed;
            if (isHosting)
            {
                UpdateAttendeePopup();
            }
            else
            {
                AttendeeListButton.IsChecked = false;
            }
            HostedMeetingCodeText.Visibility = isHosting ? Visibility.Visible : Visibility.Collapsed;
            ShowHostedMeetingButton.Visibility = isHosting ? Visibility.Visible : Visibility.Collapsed;
            EndHostedMeetingButton.Visibility = isHosting ? Visibility.Visible : Visibility.Collapsed;
            HostedMeetingCodeText.Text = $"Code {_orchestration.PairingCode}";
            UpdateCableStatus();

            var script = _model.SelectedScript;
            ScriptTitle.Text = script.Title;
            ScriptDetail.Text = $"{script.Detail} · {script.WordCount} words";

            UpdateSidebar();
            if (_showOrchestrationConfiguration && (!inSession || choosingNextHostScript))
            {
                UpdateOrchestrationConfiguration();
            }

            // Templates are not playable; they show the speaker-name entry instead.
            bool isCustom = script.IsCustom;
            TemplateNamePanel.Visibility = isCustom ? Visibility.Collapsed : Visibility.Visible;
            TransportPanel.Visibility = isCustom ? Visibility.Visible : Visibility.Collapsed;
            TimelinePanel.Visibility = isCustom ? Visibility.Visible : Visibility.Collapsed;
            LegendPanel.Visibility = isCustom ? Visibility.Visible : Visibility.Collapsed;

            var voices = _model.Voices;
            if (_model.IsLoadingVoices)
            {
                VoiceCombo.ItemsSource = new List<string> { "Loading ElevenLabs voices…" };
                VoiceCombo.SelectedIndex = 0;
                VoiceCombo.IsEnabled = false;
            }
            else
            {
                VoiceCombo.IsEnabled = true;
                var entries = voices.Select(v => v.DisplayName).ToList();
                int selectedIndex = voices.FindIndex(v => v.Id == _model.VoiceId);
                if (selectedIndex < 0)
                {
                    entries.Insert(0, _model.SelectedVoiceName);
                    selectedIndex = 0;
                }
                VoiceCombo.ItemsSource = entries;
                VoiceCombo.SelectedIndex = selectedIndex;
            }
            VoiceError.Text = _model.VoiceLoadError ?? "";
            VoiceError.Visibility = _model.VoiceLoadError is null ? Visibility.Collapsed : Visibility.Visible;

            ErrorText.Text = _model.ErrorMessage ?? "";
            ErrorText.Visibility = _model.ErrorMessage is null ? Visibility.Collapsed : Visibility.Visible;

            VolumeSlider.Value = _model.OutputVolume;
            VolumeLabel.Text = $"{Math.Round(_model.OutputVolume * 100)}%";
            VolumeIcon.Text = _model.OutputVolume switch
            {
                0 => "🔇",
                < 0.34 => "🔈",
                < 0.67 => "🔉",
                _ => "🔊",
            };
            LoopMenuItem.IsChecked = _model.LoopEnabled;

            DeviceDot.Fill = _model.SelectedDeviceAvailable ? Brushes.LimeGreen : Brushes.Orange;
            DeviceName.Text = _model.SelectedDeviceName;

            // Local controls lock while this PC is paired to a meeting orchestrator.
            // The library also locks for a host, so the meeting page cannot be
            // navigated away from while its session is live.
            bool remote = _model.IsRemoteControlled;
            bool remoteClient = _orchestration.ActiveMode == OrchestrationMode.Remote;
            // A hosting machine keeps its library clickable; navigating away asks
            // to exit the hosted meeting instead of blocking (matching macOS).
            bool libraryLocked = remoteClient;
            RemoteControlBanner.Text = "📡 " + _model.RemoteControlStatus;
            RemoteControlBanner.Visibility = remote ? Visibility.Visible : Visibility.Collapsed;
            TemplateList.IsEnabled = !libraryLocked;
            CustomList.IsEnabled = !libraryLocked;
            AddScriptButton.IsEnabled = !libraryLocked;
            RemoteModeButton.IsEnabled = !_orchestration.IsBusy;
            RemoteModeDetailText.Text = _orchestration.IsHost
                ? "Exit host meeting to be able to join remotely."
                : _orchestration.ActiveMode == OrchestrationMode.Remote
                    ? $"Paired · {_orchestration.PairingCode}"
                    : "Join with a host code";
            VoiceCombo.IsEnabled = VoiceCombo.IsEnabled && !remote;
            RefreshVoicesButton.IsEnabled = !remote && !_model.IsLoadingVoices;
            PlaybackOptionsButton.IsEnabled = !remote;

            UpdatePlayback();
        }
        finally
        {
            _suppressUiEvents = false;
        }
    }

    private void UpdatePlayback()
    {
        var player = _model.Player;
        _suppressUiEvents = true;
        try
        {
            bool remote = _model.IsRemoteControlled;
            StopButton.IsEnabled = !remote && (player.HasAudio || _model.IsGenerating);
            bool textEmpty = _model.Text.Trim().Length == 0;
            // Stay clickable while generating: hitting it during "Preparing…" or
            // "Buffering…" toggles the pending autoplay off (and back on).
            PlayButton.IsEnabled = !remote && !textEmpty;
            PlayButton.Content = player.IsBuffering
                ? (player.HasAudio ? "Buffering…" : "Preparing…")
                : player.IsPlaying ? "⏸ Pause"
                : "▶ Play";
            RegenerateButton.IsEnabled = !remote && !textEmpty;

            ProgressSlider.IsEnabled = !remote && player.HasAudio;
            ProgressSlider.Maximum = Math.Max(player.Duration, 0.01);
            if (!_isScrubbing)
            {
                ProgressSlider.Value = player.CurrentTime;
            }
            double shownTime = _isScrubbing ? ProgressSlider.Value : player.CurrentTime;
            TimeElapsed.Text = FormatTime(shownTime);
            TimeRemaining.Text = "−" + FormatTime(Math.Max(player.Duration - shownTime, 0));

            bool generating = _model.IsGenerating;
            GenerationProgress.Visibility = generating ? Visibility.Visible : Visibility.Collapsed;
            GenerationLabel.Visibility = generating ? Visibility.Visible : Visibility.Collapsed;
            if (generating)
            {
                GenerationProgress.Maximum = Math.Max(player.TotalChunkCount, 1);
                GenerationProgress.Value = player.GeneratedChunkCount;
                GenerationLabel.Text = $"Generating {player.GeneratedChunkCount}/{player.TotalChunkCount}";
            }

            RenderHighlight();
        }
        finally
        {
            _suppressUiEvents = false;
        }
    }

    private void RenderHighlight()
    {
        var text = _model.Text;
        int played = Math.Min(_model.Player.PlayedTextLength, text.Length);
        TextSpan? active = _model.Player.ActiveTextRange;
        if (text == _renderedText && played == _renderedPlayed && active == _renderedActive) return;
        bool textChanged = text != _renderedText;
        _renderedText = text;
        _renderedPlayed = played;
        _renderedActive = active;

        var paragraph = new Paragraph { Margin = new Thickness(0) };
        Run? activeRun = null;

        int activeStart = active is TextSpan span ? Math.Clamp(span.Location, 0, text.Length) : -1;
        int activeEnd = active is TextSpan span2 ? Math.Clamp(span2.Location + span2.Length, 0, text.Length) : -1;

        void AppendSegment(int start, int end, Brush? background, bool isActive)
        {
            if (end <= start) return;
            var segment = text[start..end];
            int lineStart = 0;
            bool first = true;
            while (true)
            {
                int newline = segment.IndexOf('\n', lineStart);
                string line = newline < 0 ? segment[lineStart..] : segment[lineStart..newline];
                if (line.Length > 0 || (first && newline < 0))
                {
                    var run = new Run(line) { Background = background };
                    paragraph.Inlines.Add(run);
                    if (isActive) activeRun ??= run;
                }
                if (newline < 0) break;
                paragraph.Inlines.Add(new LineBreak());
                lineStart = newline + 1;
                first = false;
                if (lineStart >= segment.Length) break;
            }
        }

        if (activeStart >= 0 && activeEnd > activeStart)
        {
            int spokenEnd = Math.Min(played, activeStart);
            AppendSegment(0, spokenEnd, SpokenBrush, isActive: false);
            AppendSegment(spokenEnd, activeStart, null, isActive: false);
            AppendSegment(activeStart, activeEnd, SpeakingBrush, isActive: true);
            AppendSegment(activeEnd, text.Length, null, isActive: false);
        }
        else
        {
            AppendSegment(0, played, SpokenBrush, isActive: false);
            AppendSegment(played, text.Length, null, isActive: false);
        }

        var document = new FlowDocument(paragraph)
        {
            FontFamily = FontFamily,
            FontSize = 13,
            PagePadding = new Thickness(0),
        };

        // Replacing the document resets the scroll position, so decide first
        // whether the reader was following the highlight. Follow it only while
        // it is already on screen; a manual scroll elsewhere sticks until the
        // highlight is scrolled back into view. A new script starts at the top.
        var scroller = ScriptScroller;
        bool follow = scroller is null || IsRunVisible(_renderedActiveRun, scroller);
        double offset = scroller?.VerticalOffset ?? 0;
        ScriptViewer.Document = document;
        _renderedActiveRun = activeRun;
        if (textChanged) return;
        if (follow && activeRun is not null)
        {
            activeRun.BringIntoView();
        }
        else if (scroller is not null)
        {
            scroller.Dispatcher.BeginInvoke(
                DispatcherPriority.Loaded,
                new Action(() => scroller.ScrollToVerticalOffset(offset)));
        }
    }

    private ScrollViewer? ScriptScroller
    {
        get
        {
            if (_scriptScroller is null)
            {
                ScriptViewer.ApplyTemplate();
                _scriptScroller = ScriptViewer.Template?.FindName("PART_ContentHost", ScriptViewer) as ScrollViewer;
            }
            return _scriptScroller;
        }
    }

    private static bool IsRunVisible(Run? run, ScrollViewer scroller)
    {
        if (run is null) return true;
        var rect = run.ContentStart.GetCharacterRect(LogicalDirection.Forward);
        return !rect.IsEmpty && rect.Bottom > 0 && rect.Top < scroller.ViewportHeight;
    }

    private static string FormatTime(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0) return "0:00";
        int total = (int)Math.Floor(seconds);
        return $"{total / 60}:{total % 60:00}";
    }

    // Event handlers

    private void OnSettingsClick(object sender, RoutedEventArgs e)
    {
        if (_settingsWindow is null || !_settingsWindow.IsLoaded)
        {
            _settingsWindow = new SettingsWindow(_model) { Owner = this };
        }
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private void UpdateSidebar()
    {
        var templateItems = new List<ListBoxItem>();
        var isFirstScenario = true;
        foreach (var scenario in _model.BundledScriptGroups)
        {
            templateItems.Add(BuildSidebarHeader(scenario.Title, isFirstScenario));
            templateItems.AddRange(scenario.Excerpts.Select(e => BuildSidebarItem(e.SpeechScript, isTemplate: true)));
            isFirstScenario = false;
        }
        templateItems.Add(BuildSidebarHeader("Orchestrated meeting", isFirstScenario: false));
        templateItems.AddRange(OrchestratedMeetingTemplate.All.Select(BuildOrchestratedMeetingItem));
        TemplateList.ItemsSource = templateItems;
        TemplateList.SelectedItem = _showOrchestrationConfiguration
            ? templateItems.FirstOrDefault(i => i.Tag as string == "orchestrated:" + _orchestration.SelectedTemplate.Id)
            : templateItems.FirstOrDefault(i => i.Tag as string == _model.SelectedScriptId);

        var custom = _model.PlayableScripts;
        CustomList.ItemsSource = custom.Select(s => BuildSidebarItem(s, isTemplate: false)).ToList();
        CustomList.SelectedIndex = custom.FindIndex(s => s.Id == _model.SelectedScriptId);
        CustomEmptyHint.Visibility = custom.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private ListBoxItem BuildOrchestratedMeetingItem(OrchestratedMeetingTemplate template)
    {
        var panel = new StackPanel { Margin = new Thickness(2, 3, 2, 3) };
        panel.Children.Add(new TextBlock
        {
            Text = "👥 " + template.Title,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        panel.Children.Add(new TextBlock
        {
            Text = $"{template.Detail} · {template.TurnCount} turns",
            FontSize = 10,
            Foreground = Brushes.Gray,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        bool canChoose = !_orchestration.IsActive
            || (_orchestration.IsHost
                && ((_orchestration.SessionStatus == OrchestrationSessionStatus.Lobby && _orchestration.Turns.Count == 0)
                    || _orchestration.SessionStatus is OrchestrationSessionStatus.Completed or OrchestrationSessionStatus.Stopped));
        return new ListBoxItem { Content = panel, Tag = "orchestrated:" + template.Id, IsEnabled = canChoose };
    }

    private static ListBoxItem BuildSidebarHeader(string title, bool isFirstScenario)
    {
        return new ListBoxItem
        {
            IsEnabled = false,
            Focusable = false,
            Padding = new Thickness(0),
            Margin = new Thickness(4, isFirstScenario ? 4 : 12, 0, 2),
            Content = new TextBlock
            {
                Text = title.ToUpperInvariant(),
                FontSize = 10,
                FontWeight = FontWeights.Bold,
                Foreground = Brushes.Gray,
                TextTrimming = TextTrimming.CharacterEllipsis,
            },
        };
    }

    private ListBoxItem BuildSidebarItem(SpeechScript script, bool isTemplate)
    {
        var panel = new StackPanel { Margin = new Thickness(2, 3, 2, 3) };
        panel.Children.Add(new TextBlock
        {
            Text = (isTemplate ? "👤 " : "🔊 ") + script.Title,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        panel.Children.Add(new TextBlock
        {
            Text = $"{script.Detail} · {script.WordCount} words",
            FontSize = 10,
            Foreground = Brushes.Gray,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });

        var item = new ListBoxItem
        {
            Content = panel,
            Tag = script.Id,
            IsEnabled = !_orchestration.IsActive || _orchestration.IsHost,
        };
        var menu = new ContextMenu();
        if (isTemplate)
        {
            var replicate = new MenuItem { Header = "Replicate…" };
            replicate.Click += (_, _) =>
            {
                _showOrchestrationConfiguration = false;
                _model.SelectScript(script.Id);
            };
            menu.Items.Add(replicate);
        }
        else
        {
            var edit = new MenuItem { Header = "Edit…" };
            edit.Click += (_, _) =>
            {
                _model.SelectScript(script.Id);
                OpenScriptEditor(forNewScript: false);
            };
            var delete = new MenuItem { Header = "Delete…" };
            delete.Click += (_, _) => ConfirmDeleteScript(script);
            menu.Items.Add(edit);
            menu.Items.Add(new Separator());
            menu.Items.Add(delete);
        }
        item.ContextMenu = menu;
        return item;
    }

    private async void OnTemplateListSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressUiEvents) return;
        if (TemplateList.SelectedItem is ListBoxItem { Tag: string id })
        {
            if (id.StartsWith("orchestrated:", StringComparison.Ordinal))
            {
                var templateId = id["orchestrated:".Length..];
                var template = OrchestratedMeetingTemplate.All.FirstOrDefault(item => item.Id == templateId);
                if (template is null) return;
                _orchestration.SelectTemplate(template);
                _showRemoteMode = false;
                _showOrchestrationSession = false;
                _showOrchestrationConfiguration = true;
                CustomList.SelectedItem = null;
                UpdateAll();
            }
            else
            {
                if (_orchestration.IsActive && !_orchestration.IsHost) return;
                if (!await ConfirmExitHostedMeetingIfNeededAsync()) { UpdateAll(); return; }
                _showOrchestrationConfiguration = false;
                _showRemoteMode = false;
                _model.SelectScript(id);
            }
        }
    }

    private async void OnCustomListSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressUiEvents) return;
        if (CustomList.SelectedItem is ListBoxItem { Tag: string id })
        {
            if (_orchestration.IsActive && !_orchestration.IsHost) return;
            if (!await ConfirmExitHostedMeetingIfNeededAsync()) { UpdateAll(); return; }
            _showOrchestrationConfiguration = false;
            _showRemoteMode = false;
            _model.SelectScript(id);
        }
    }

    /// <summary>
    /// Navigating the library away from a hosted meeting asks to exit it first.
    /// Returns false when the user keeps hosting (the caller re-syncs the UI).
    /// </summary>
    private async Task<bool> ConfirmExitHostedMeetingIfNeededAsync()
    {
        if (!_orchestration.IsHost) return true;
        var confirmation = MessageBox.Show(
            this,
            "This ends the hosted meeting and disconnects its paired speakers.",
            "Exit hosted meeting?",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No);
        if (confirmation != MessageBoxResult.Yes) return false;
        await _orchestration.LeaveSessionAsync();
        _showOrchestrationSession = false;
        return true;
    }

    private const string AttendeeDragFormat = "BotSpeakerAttendeeId";

    private void UpdateOrchestrationConfiguration()
    {
        _orchestration.ApplyDefaultTemplateVoices();
        SpeakerConfigurationList.Children.Clear();
        var participantsById = _orchestration.Participants.ToDictionary(p => p.Id);
        bool canArrange = _orchestration.IsHost
            && _orchestration.SessionStatus == OrchestrationSessionStatus.Lobby
            && _orchestration.Turns.Count == 0;
        foreach (var configuration in _orchestration.SpeakerConfigurations)
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(185) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 12 });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            int slot = configuration.Slot;
            int seatIndex = slot - 1;
            var editNameButton = new Button
            {
                Content = new TextBlock
                {
                    Text = "\uE70F",
                    FontFamily = new FontFamily("Segoe MDL2 Assets"),
                    FontSize = 12,
                },
                Width = 28,
                Height = 24,
                Padding = new Thickness(0),
                ToolTip = "Edit speaker name",
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
            };
            editNameButton.Click += (_, _) =>
            {
                var editedName = ShowSpeakerNameDialog(configuration.Name);
                if (editedName is null) return;
                _orchestration.UpdateSpeakerName(slot, editedName);
                UpdateOrchestrationConfiguration();
            };
            Grid.SetColumn(editNameButton, 0);
            row.Children.Add(editNameButton);

            var identity = new StackPanel();
            identity.Children.Add(new TextBlock
            {
                Text = string.IsNullOrWhiteSpace(configuration.Name) ? configuration.Placeholder : configuration.Name,
                FontFamily = string.IsNullOrWhiteSpace(configuration.Name)
                    ? new FontFamily("Consolas")
                    : new FontFamily("Segoe UI"),
                FontSize = 14,
                FontWeight = FontWeights.SemiBold,
            });
            identity.Children.Add(new TextBlock
            {
                Text = configuration.Role,
                FontSize = 11,
                Foreground = Brushes.Gray,
            });
            Grid.SetColumn(identity, 1);
            row.Children.Add(identity);

            var voiceCombo = new ComboBox
            {
                ItemsSource = _model.Voices,
                ItemTemplate = (DataTemplate)FindResource("CompactVoiceItemTemplate"),
                SelectedValuePath = nameof(ElevenLabsVoice.Id),
                SelectedValue = configuration.VoiceId,
                IsEnabled = !_model.IsLoadingVoices,
                MinWidth = 120,
                VerticalAlignment = VerticalAlignment.Center,
            };
            voiceCombo.SelectionChanged += (_, _) =>
            {
                if (_suppressUiEvents || voiceCombo.SelectedValue is not string voiceId) return;
                _orchestration.UpdateSpeakerVoice(slot, voiceId);
                RefreshOrchestrationPreview();
            };
            Grid.SetColumn(voiceCombo, 2);
            row.Children.Add(voiceCombo);

            var occupantId = _orchestration.SeatAssignments
                .Where(pair => pair.Value == seatIndex)
                .Select(pair => pair.Key)
                .FirstOrDefault();
            FrameworkElement seatView = occupantId is not null && participantsById.TryGetValue(occupantId, out var occupant)
                ? BuildAttendeeChip(occupant, canDrag: canArrange)
                : BuildVacantSeatChip();
            seatView.VerticalAlignment = VerticalAlignment.Center;
            seatView.HorizontalAlignment = HorizontalAlignment.Right;
            Grid.SetColumn(seatView, 4);
            row.Children.Add(seatView);

            SpeakerConfigurationList.Children.Add(MakeAttendeeDropTarget(
                row, canArrange, attendeeId => _orchestration.AssignParticipant(attendeeId, seatIndex)));
        }

        var benched = _orchestration.ParticipantOrder
            .Where(id => !_orchestration.SeatAssignments.ContainsKey(id) && participantsById.ContainsKey(id))
            .Select(id => participantsById[id])
            .ToList();
        if (benched.Count > 0)
        {
            SpeakerConfigurationList.Children.Add(new Separator { Margin = new Thickness(0, 8, 0, 6) });
            var benchPanel = new StackPanel();
            benchPanel.Children.Add(new TextBlock
            {
                Text = "Not in this meeting",
                FontSize = 11,
                FontWeight = FontWeights.SemiBold,
                Foreground = Brushes.Gray,
            });
            benchPanel.Children.Add(new TextBlock
            {
                Text = "Drag an attendee onto a speaker row to seat them, or drop them here to bench them.",
                FontSize = 10,
                Foreground = Brushes.Gray,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 6),
            });
            var chips = new WrapPanel();
            foreach (var attendee in benched)
            {
                var chip = BuildAttendeeChip(attendee, canDrag: canArrange);
                chip.Margin = new Thickness(0, 0, 6, 6);
                chips.Children.Add(chip);
            }
            benchPanel.Children.Add(chips);
            SpeakerConfigurationList.Children.Add(MakeAttendeeDropTarget(
                benchPanel, canArrange, attendeeId => _orchestration.BenchParticipant(attendeeId)));
        }
        RefreshOrchestrationPreview();
    }

    private Border BuildAttendeeChip(OrchestrationParticipant attendee, bool canDrag)
    {
        string label = attendee.Id == _orchestration.LocalParticipantId
            ? $"{attendee.DisplayName} (this PC)"
            : attendee.DisplayName;
        var chip = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0x22, 0x80, 0x80, 0x80)),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(9, 3, 9, 3),
            Child = new TextBlock
            {
                Text = "👤 " + label,
                FontSize = 12,
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxWidth = 180,
            },
        };
        if (!canDrag) return chip;
        chip.Cursor = Cursors.SizeAll;
        chip.ToolTip = "Drag onto a speaker row or the bench";
        string id = attendee.Id;
        chip.MouseMove += (_, args) =>
        {
            if (args.LeftButton != MouseButtonState.Pressed) return;
            DragDrop.DoDragDrop(chip, new DataObject(AttendeeDragFormat, id), DragDropEffects.Move);
        };
        return chip;
    }

    private static Border BuildVacantSeatChip() => new()
    {
        BorderBrush = Brushes.Gray,
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(10),
        Padding = new Thickness(9, 3, 9, 3),
        Child = new TextBlock
        {
            Text = "Vacant seat",
            FontSize = 12,
            FontStyle = FontStyles.Italic,
            Foreground = Brushes.Gray,
        },
    };

    private static Border MakeAttendeeDropTarget(UIElement child, bool isEnabled, Action<string> onDrop)
    {
        var target = new Border
        {
            Child = child,
            CornerRadius = new CornerRadius(6),
            Background = Brushes.Transparent,
            Padding = new Thickness(4, 6, 4, 6),
            AllowDrop = isEnabled,
        };
        if (!isEnabled) return target;
        var highlight = new SolidColorBrush(Color.FromArgb(0x33, 0x2E, 0x6B, 0xD6));
        void HandleDragOver(object _, DragEventArgs args)
        {
            bool hasAttendee = args.Data.GetDataPresent(AttendeeDragFormat);
            args.Effects = hasAttendee ? DragDropEffects.Move : DragDropEffects.None;
            args.Handled = true;
            if (hasAttendee) target.Background = highlight;
        }
        target.DragEnter += HandleDragOver;
        target.DragOver += HandleDragOver;
        target.DragLeave += (_, _) => target.Background = Brushes.Transparent;
        target.Drop += (_, args) =>
        {
            target.Background = Brushes.Transparent;
            if (args.Data.GetData(AttendeeDragFormat) is string attendeeId) onDrop(attendeeId);
            args.Handled = true;
        };
        return target;
    }

    private void UpdateAttendeePopup()
    {
        var attendees = _orchestration.Participants
            .Where(p => p.Id != _orchestration.LocalParticipantId)
            .ToList();
        AttendeePopupList.Children.Clear();
        AttendeePopupEmptyText.Visibility = attendees.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        AttendeePopupEmptyText.Text =
            $"No remote speakers yet. Share code {_orchestration.PairingCode} to invite this meeting's speakers.";
        foreach (var attendee in attendees)
        {
            var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
            var dot = new System.Windows.Shapes.Ellipse
            {
                Width = 8,
                Height = 8,
                Fill = attendee.IsRecentlyConnected ? Brushes.LimeGreen : Brushes.Orange,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 8, 0),
            };
            DockPanel.SetDock(dot, Dock.Left);
            row.Children.Add(dot);
            var text = new StackPanel();
            text.Children.Add(new TextBlock
            {
                Text = attendee.DisplayName,
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            text.Children.Add(new TextBlock
            {
                Text = attendee.IsRecentlyConnected ? "Connected" : "Connection lost",
                FontSize = 10,
                Foreground = Brushes.Gray,
            });
            row.Children.Add(text);
            AttendeePopupList.Children.Add(row);
        }
    }

    private void RefreshOrchestrationPreview()
    {
        OrchestrationTemplateTitle.Text = _orchestration.SelectedTemplate.Title;
        OrchestrationScriptPreview.Text = _orchestration.ConfiguredScriptPreview;
        PrepareMeetingButton.Content = _orchestration.IsHost
            ? _orchestration.SessionStatus is OrchestrationSessionStatus.Completed or OrchestrationSessionStatus.Stopped
                ? "Use for Next Run"
                : "Use This Script"
            : "Host & Use This Script";
        PrepareMeetingButton.IsEnabled = !_orchestration.IsBusy;
    }

    private string? ShowSpeakerNameDialog(string currentName)
    {
        string? result = null;
        var dialog = new Window
        {
            Title = "Edit Speaker Name",
            Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.NoResize,
            SizeToContent = SizeToContent.Height,
            Width = 390,
            ShowInTaskbar = false,
        };
        var content = new StackPanel { Margin = new Thickness(22) };
        content.Children.Add(new TextBlock
        {
            Text = "Replaces the placeholder throughout the script.",
            Foreground = Brushes.Gray,
            Margin = new Thickness(0, 0, 0, 12),
        });
        var nameBox = new TextBox
        {
            Text = currentName,
            Padding = new Thickness(5),
            Margin = new Thickness(0, 0, 0, 16),
        };
        content.Children.Add(nameBox);

        var buttons = new Grid();
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(10) });
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var cancelButton = new Button { Content = "Cancel", IsCancel = true, Padding = new Thickness(10, 5, 10, 5) };
        var saveButton = new Button
        {
            Content = "Save",
            IsDefault = true,
            IsEnabled = !string.IsNullOrWhiteSpace(currentName),
            Padding = new Thickness(10, 5, 10, 5),
        };
        nameBox.TextChanged += (_, _) => saveButton.IsEnabled = !string.IsNullOrWhiteSpace(nameBox.Text);
        saveButton.Click += (_, _) =>
        {
            result = nameBox.Text.Trim();
            dialog.DialogResult = true;
        };
        Grid.SetColumn(cancelButton, 0);
        Grid.SetColumn(saveButton, 2);
        buttons.Children.Add(cancelButton);
        buttons.Children.Add(saveButton);
        content.Children.Add(buttons);
        dialog.Content = content;
        dialog.Loaded += (_, _) =>
        {
            nameBox.Focus();
            nameBox.SelectAll();
        };
        dialog.ShowDialog();
        return result;
    }

    private async void OnOpenMeetingSetupClick(object sender, RoutedEventArgs e)
    {
        SetMeetingEntryButtonsEnabled(false);
        if (_orchestration.IsHost)
        {
            await _orchestration.UseSelectedTemplateInHostedGroupAsync();
        }
        else
        {
            _orchestration.PrepareHostSetup();
            await _orchestration.StartHostingAsync();
        }
        SetMeetingEntryButtonsEnabled(true);
        if (_orchestration.IsHost)
        {
            _showOrchestrationConfiguration = false;
            _showOrchestrationSession = true;
            UpdateAll();
        }
        else if (_orchestration.ErrorMessage is string error)
        {
            MessageBox.Show(this, error, "Couldn’t host meeting", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async void OnJoinMeetingClick(object sender, RoutedEventArgs e)
    {
        _orchestration.SpeakerName = RemoteSpeakerNameBox.Text;
        _orchestration.PrepareRemoteSetup();
        _orchestration.PairingCodeInput = RemotePairingCodeBox.Text;
        SetMeetingEntryButtonsEnabled(false);
        await _orchestration.JoinMeetingAsync();
        SetMeetingEntryButtonsEnabled(true);
        if (_orchestration.IsActive)
        {
            _showOrchestrationSession = true;
            UpdateAll();
        }
        else if (_orchestration.ErrorMessage is string error)
        {
            MessageBox.Show(this, error, "Couldn’t join meeting", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void SetMeetingEntryButtonsEnabled(bool isEnabled)
    {
        PrepareMeetingButton.IsEnabled = isEnabled;
        RemoteJoinButton.IsEnabled = isEnabled;
    }

    private async void OnRemoteModeClick(object sender, RoutedEventArgs e)
    {
        if (_orchestration.IsHost)
        {
            var confirmation = MessageBox.Show(
                this,
                "This ends the hosted meeting and disconnects its paired speakers. You can then join another meeting in Remote Mode.",
                "Exit hosted meeting?",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);
            if (confirmation != MessageBoxResult.Yes) return;
            await _orchestration.LeaveSessionAsync();
            _showOrchestrationSession = false;
        }
        _showOrchestrationConfiguration = false;
        _showRemoteMode = true;
        TemplateList.SelectedItem = null;
        CustomList.SelectedItem = null;
        UpdateAll();
        RemotePairingCodeBox.Focus();
    }

    private async void OnHostMeetingClick(object sender, RoutedEventArgs e)
    {
        _orchestration.PrepareHostSetup();
        HostMeetingButton.IsEnabled = false;
        await _orchestration.StartHostingAsync();
        _showOrchestrationSession = false;
        UpdateAll();
        if (!_orchestration.IsHost && _orchestration.ErrorMessage is string error)
        {
            MessageBox.Show(this, error, "Couldn’t host meeting", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void OnShowHostedMeetingClick(object sender, RoutedEventArgs e)
    {
        if (!_orchestration.IsHost) return;
        _showRemoteMode = false;
        _showOrchestrationConfiguration = false;
        _showOrchestrationSession = true;
        UpdateAll();
    }

    private async void OnEndHostedMeetingClick(object sender, RoutedEventArgs e)
    {
        await _orchestration.LeaveSessionAsync();
        _showOrchestrationSession = false;
        _showOrchestrationConfiguration = false;
        UpdateAll();
    }

    private void OnRemotePairingCodeKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        OnJoinMeetingClick(sender, new RoutedEventArgs());
    }

    private async void OnAddScriptClick(object sender, RoutedEventArgs e)
    {
        if (!await ConfirmExitHostedMeetingIfNeededAsync()) return;
        OpenScriptEditor(forNewScript: true);
    }

    private void OpenScriptEditor(bool forNewScript)
    {
        _showOrchestrationConfiguration = false;
        _showRemoteMode = false;
        if (_scriptEditor is null || !_scriptEditor.IsLoaded)
        {
            _scriptEditor = new ScriptEditorWindow(_model) { Owner = this };
        }
        if (forNewScript)
        {
            _scriptEditor.PrepareForNewScript();
        }
        else
        {
            _scriptEditor.PrepareForSelectedScript();
        }
        _scriptEditor.Show();
        _scriptEditor.Activate();
    }

    private void ConfirmDeleteScript(SpeechScript script)
    {
        if (script.CustomId is not Guid id) return;
        var result = MessageBox.Show(
            this,
            "This permanently removes the saved script. This action can't be undone.",
            $"Delete {script.Title}?",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);
        if (result == MessageBoxResult.Yes)
        {
            _model.DeleteCustomScript(id);
        }
    }

    private void OnCreateScriptClick(object sender, RoutedEventArgs e) => CreateNamedScript();

    private void OnSpeakerNameKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        CreateNamedScript();
    }

    private void CreateNamedScript()
    {
        try
        {
            _model.CreateNamedScriptFromSelectedTemplate(SpeakerNameBox.Text);
            SpeakerNameBox.Clear();
            TemplateHint.Text = "Replaces {{name}} once and creates an independent, playable copy.";
            TemplateHint.Foreground = Brushes.Gray;
        }
        catch (AppException error)
        {
            TemplateHint.Text = "⚠ " + error.Message;
            TemplateHint.Foreground = Brushes.Red;
        }
    }

    private async void OnRefreshVoicesClick(object sender, RoutedEventArgs e) =>
        await _model.RefreshVoicesAsync();

    private void OnVoiceSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressUiEvents || _model.IsLoadingVoices) return;
        var voices = _model.Voices;
        int index = VoiceCombo.SelectedIndex;
        bool hasPlaceholder = voices.FindIndex(v => v.Id == _model.VoiceId) < 0
            && VoiceCombo.Items.Count == voices.Count + 1;
        if (hasPlaceholder)
        {
            if (index == 0) return;
            index--;
        }
        if (index >= 0 && index < voices.Count && voices[index].Id != _model.VoiceId)
        {
            _model.VoiceId = voices[index].Id;
        }
    }

    private void OnStopClick(object sender, RoutedEventArgs e) => _model.StopPlayback();

    private async void OnPlayClick(object sender, RoutedEventArgs e) => await _model.PrimaryActionAsync();

    private async void OnRegenerateClick(object sender, RoutedEventArgs e) => await _model.RegenerateAsync();

    private void OnVolumeChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_suppressUiEvents) return;
        _model.OutputVolume = e.NewValue;
    }

    private void OnPlaybackOptionsClick(object sender, RoutedEventArgs e)
    {
        var menu = PlaybackOptionsButton.ContextMenu!;
        menu.PlacementTarget = PlaybackOptionsButton;
        menu.Placement = PlacementMode.Bottom;
        menu.IsOpen = true;
    }

    private void OnLoopChanged(object sender, RoutedEventArgs e)
    {
        if (_suppressUiEvents) return;
        _model.LoopEnabled = LoopMenuItem.IsChecked;
    }

    private void OnScrubStarted(object sender, DragStartedEventArgs e) => _isScrubbing = true;

    private void OnScrubCompleted(object sender, DragCompletedEventArgs e)
    {
        _isScrubbing = false;
        _model.Player.Seek(ProgressSlider.Value);
    }

    private void OnProgressSliderChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_suppressUiEvents || _isScrubbing) return;
        // Click-to-seek (IsMoveToPointEnabled) changes the value without a thumb drag.
        if (Math.Abs(e.NewValue - _model.Player.CurrentTime) > 0.5)
        {
            _model.Player.Seek(e.NewValue);
        }
    }

    // First-run overlay

    private void UpdateCableStatus()
    {
        bool hasCable = _model.Devices.OutputDevices.Any(d => d.IsVirtualCable);
        CableStatus.Text = hasCable ? "✅ Virtual audio cable detected" : "⚠️ No virtual audio cable found";
        CableStatus.Foreground = hasCable ? Brushes.Green : Brushes.DarkOrange;
        CableHelp.Visibility = hasCable ? Visibility.Collapsed : Visibility.Visible;
    }

    private async void OnValidateKeyClick(object sender, RoutedEventArgs e)
    {
        FirstRunContinueButton.IsEnabled = false;
        FirstRunError.Visibility = Visibility.Collapsed;
        try
        {
            await _model.ValidateAndSaveApiKeyAsync(FirstRunKeyBox.Password);
            FirstRunKeyBox.Clear();
        }
        catch (Exception error)
        {
            FirstRunError.Text = error.Message;
            FirstRunError.Visibility = Visibility.Visible;
        }
        finally
        {
            FirstRunContinueButton.IsEnabled = true;
        }
    }

    private void OnQuitClick(object sender, RoutedEventArgs e) =>
        ((App)Application.Current).ExitApplication();

    private void OnLinkNavigate(object sender, RequestNavigateEventArgs e)
    {
        Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
        e.Handled = true;
    }
}
