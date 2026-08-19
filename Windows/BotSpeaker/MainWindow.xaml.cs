using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Navigation;

namespace BotSpeaker;

public partial class MainWindow : Window
{
    private readonly AppModel _model;
    private bool _isScrubbing;
    private bool _suppressUiEvents;
    private ScriptEditorWindow? _scriptEditor;
    private SettingsWindow? _settingsWindow;

    private static readonly Brush SpokenBrush = new SolidColorBrush(Color.FromArgb(0x59, 0x34, 0xC7, 0x59));
    private static readonly Brush SpeakingBrush = new SolidColorBrush(Color.FromArgb(0x8C, 0x2E, 0x6B, 0xD6));

    private string _renderedText = "";
    private int _renderedPlayed = -1;
    private TextSpan? _renderedActive;

    public MainWindow(AppModel model)
    {
        _model = model;
        InitializeComponent();

        _model.PropertyChanged += OnModelChanged;
        _model.Player.PropertyChanged += OnPlayerChanged;
        _model.InterruptionMonitor.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(UpdateInterruptionBanner);

        Loaded += async (_, _) =>
        {
            UpdateAll();
            if (_model.HasApiKey) await _model.LoadVoicesIfNeededAsync();
        };
        Closing += OnWindowClosing;
        PreviewKeyDown += OnWindowPreviewKeyDown;
    }

    private async void OnWindowPreviewKeyDown(object sender, KeyEventArgs e)
    {
        // Space toggles play/pause while the window is foregrounded, unless the user
        // is typing in an editable field or operating a control that consumes space.
        if (e.Key != Key.Space || !_model.HasApiKey) return;
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
            UpdateCableStatus();

            var script = _model.SelectedScript;
            ScriptTitle.Text = script.Title;
            ScriptDetail.Text = $"{script.Detail} · {script.WordCount} words";

            UpdateSidebar();

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
            InterruptionMenuItem.IsChecked = _model.InterruptionEnabled;

            DeviceDot.Fill = _model.SelectedDeviceAvailable ? Brushes.LimeGreen : Brushes.Orange;
            DeviceName.Text = _model.SelectedDeviceName;

            // Local controls lock while this PC is paired to a meeting orchestrator.
            bool remote = _model.IsRemoteControlled;
            RemoteControlBanner.Text = "📡 " + _model.RemoteControlStatus;
            RemoteControlBanner.Visibility = remote ? Visibility.Visible : Visibility.Collapsed;
            TemplateList.IsEnabled = !remote;
            CustomList.IsEnabled = !remote;
            AddScriptButton.IsEnabled = !remote;
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

            UpdateInterruptionBanner();
            RenderHighlight();
        }
        finally
        {
            _suppressUiEvents = false;
        }
    }

    private void UpdateInterruptionBanner()
    {
        var player = _model.Player;
        bool visible = _model.InterruptionMonitor.IsHearingAudio || player.IsWaitingForInterruption;
        InterruptionBanner.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        InterruptionBanner.Text = player.IsWaitingForInterruption
            ? "👂 Paused for an interruption"
            : "👂 Interruption detected";
    }

    private void RenderHighlight()
    {
        var text = _model.Text;
        int played = Math.Min(_model.Player.PlayedTextLength, text.Length);
        TextSpan? active = _model.Player.ActiveTextRange;
        if (text == _renderedText && played == _renderedPlayed && active == _renderedActive) return;
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
        ScriptViewer.Document = document;
        activeRun?.BringIntoView();
    }

    private static string FormatTime(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0) return "0:00";
        int total = (int)Math.Floor(seconds);
        return $"{total / 60}:{total % 60:00}";
    }

    // Event handlers

    private void OnOrchestratorClick(object sender, RoutedEventArgs e) =>
        ((App)Application.Current).ShowOrchestrationWindow();

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
        TemplateList.ItemsSource = templateItems;
        TemplateList.SelectedItem = templateItems.FirstOrDefault(i => i.Tag as string == _model.SelectedScriptId);

        var custom = _model.PlayableScripts;
        CustomList.ItemsSource = custom.Select(s => BuildSidebarItem(s, isTemplate: false)).ToList();
        CustomList.SelectedIndex = custom.FindIndex(s => s.Id == _model.SelectedScriptId);
        CustomEmptyHint.Visibility = custom.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
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

        var item = new ListBoxItem { Content = panel, Tag = script.Id };
        var menu = new ContextMenu();
        if (isTemplate)
        {
            var replicate = new MenuItem { Header = "Replicate…" };
            replicate.Click += (_, _) => _model.SelectScript(script.Id);
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

    private void OnTemplateListSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressUiEvents) return;
        if (TemplateList.SelectedItem is ListBoxItem { Tag: string id })
        {
            _model.SelectScript(id);
        }
    }

    private void OnCustomListSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressUiEvents) return;
        if (CustomList.SelectedItem is ListBoxItem { Tag: string id })
        {
            _model.SelectScript(id);
        }
    }

    private void OnAddScriptClick(object sender, RoutedEventArgs e) => OpenScriptEditor(forNewScript: true);

    private void OpenScriptEditor(bool forNewScript)
    {
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

    private void OnInterruptionChanged(object sender, RoutedEventArgs e)
    {
        if (_suppressUiEvents) return;
        _model.InterruptionEnabled = InterruptionMenuItem.IsChecked;
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
