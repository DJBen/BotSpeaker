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
        var focused = Keyboard.FocusedElement;
        if (focused is PasswordBox) return;
        if (focused is TextBoxBase editable && !editable.IsReadOnly) return;
        if (focused is ComboBox || focused is ComboBoxItem) return;
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
            ScriptKind.Text = script.IsCustom ? "📄 Custom script" : "🔒 Built-in example · Read only";
            EditScriptButton.Content = script.IsCustom ? "Edit" : "Add Text";

            var scripts = _model.AvailableScripts;
            ScriptCombo.ItemsSource = scripts.Select(s => s.IsCustom ? s.Title : $"{s.Title} — {s.Detail}").ToList();
            ScriptCombo.SelectedIndex = scripts.FindIndex(s => s.Id == _model.SelectedScriptId);

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
            StopButton.IsEnabled = player.HasAudio || _model.IsGenerating;
            bool textEmpty = _model.Text.Trim().Length == 0;
            bool preparing = _model.IsGenerating && !player.HasAudio;
            PlayButton.IsEnabled = !preparing && !textEmpty;
            PlayButton.Content = preparing ? "Preparing…"
                : player.IsBuffering ? "Buffering…"
                : player.IsPlaying ? "⏸ Pause"
                : "▶ Play";
            RegenerateButton.IsEnabled = !textEmpty;

            ProgressSlider.IsEnabled = player.HasAudio;
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

    private void OnSettingsClick(object sender, RoutedEventArgs e)
    {
        if (_settingsWindow is null || !_settingsWindow.IsLoaded)
        {
            _settingsWindow = new SettingsWindow(_model) { Owner = this };
        }
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private void OnScriptSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressUiEvents) return;
        var scripts = _model.AvailableScripts;
        int index = ScriptCombo.SelectedIndex;
        if (index >= 0 && index < scripts.Count)
        {
            _model.SelectScript(scripts[index].Id);
        }
    }

    private void OnEditScriptClick(object sender, RoutedEventArgs e)
    {
        if (_scriptEditor is null || !_scriptEditor.IsLoaded)
        {
            _scriptEditor = new ScriptEditorWindow(_model) { Owner = this };
        }
        _scriptEditor.PrepareForSelectedScript();
        _scriptEditor.Show();
        _scriptEditor.Activate();
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
