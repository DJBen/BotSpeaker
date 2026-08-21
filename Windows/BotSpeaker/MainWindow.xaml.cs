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
    private bool _isScrubbing;
    private bool _suppressUiEvents;
    private ScriptEditorWindow? _scriptEditor;
    private SettingsWindow? _settingsWindow;

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
            ComposerPanel.Visibility = _showOrchestrationConfiguration ? Visibility.Collapsed : Visibility.Visible;
            OrchestrationConfigurationPanel.Visibility = _showOrchestrationConfiguration
                ? Visibility.Visible
                : Visibility.Collapsed;
            UpdateCableStatus();

            var script = _model.SelectedScript;
            ScriptTitle.Text = script.Title;
            ScriptDetail.Text = $"{script.Detail} · {script.WordCount} words";

            UpdateSidebar();
            if (_showOrchestrationConfiguration) UpdateOrchestrationConfiguration();

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
        return new ListBoxItem { Content = panel, Tag = "orchestrated:" + template.Id };
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

    private void OnTemplateListSelected(object sender, SelectionChangedEventArgs e)
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
                _showOrchestrationConfiguration = true;
                CustomList.SelectedItem = null;
                UpdateAll();
            }
            else
            {
                _showOrchestrationConfiguration = false;
                _model.SelectScript(id);
            }
        }
    }

    private void OnCustomListSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressUiEvents) return;
        if (CustomList.SelectedItem is ListBoxItem { Tag: string id })
        {
            _showOrchestrationConfiguration = false;
            _model.SelectScript(id);
        }
    }

    private void UpdateOrchestrationConfiguration()
    {
        _orchestration.ApplyDefaultTemplateVoices();
        SpeakerConfigurationList.Children.Clear();
        foreach (var configuration in _orchestration.SpeakerConfigurations)
        {
            var row = new Grid { Margin = new Thickness(2, 5, 2, 5) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(185) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            int slot = configuration.Slot;
            var editNameButton = new Button
            {
                Content = new TextBlock
                {
                    Text = "\uE70F",
                    FontFamily = new FontFamily("Segoe MDL2 Assets"),
                    FontSize = 12,
                },
                Width = 24,
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
                FontSize = 11,
            });
            identity.Children.Add(new TextBlock
            {
                Text = configuration.Role,
                FontSize = 10,
                Foreground = Brushes.Gray,
            });
            Grid.SetColumn(identity, 1);
            row.Children.Add(identity);

            var voiceCombo = new ComboBox
            {
                ItemsSource = _model.Voices,
                DisplayMemberPath = nameof(ElevenLabsVoice.DisplayName),
                SelectedValuePath = nameof(ElevenLabsVoice.Id),
                SelectedValue = configuration.VoiceId,
                IsEnabled = !_model.IsLoadingVoices,
            };
            voiceCombo.SelectionChanged += (_, _) =>
            {
                if (_suppressUiEvents || voiceCombo.SelectedValue is not string voiceId) return;
                _orchestration.UpdateSpeakerVoice(slot, voiceId);
                RefreshOrchestrationPreview();
            };
            Grid.SetColumn(voiceCombo, 3);
            row.Children.Add(voiceCombo);
            SpeakerConfigurationList.Children.Add(row);
        }
        RefreshOrchestrationPreview();
    }

    private void RefreshOrchestrationPreview()
    {
        OrchestrationTemplateTitle.Text = _orchestration.SelectedTemplate.Title;
        OrchestrationScriptPreview.Text = _orchestration.ConfiguredScriptPreview;
        PrepareMeetingButton.IsEnabled = true;
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

    private void OnOpenMeetingSetupClick(object sender, RoutedEventArgs e)
    {
        _orchestration.PrepareHostSetup();
        ((App)Application.Current).ShowOrchestrationWindow();
    }

    private void OnJoinMeetingClick(object sender, RoutedEventArgs e)
    {
        if (!_orchestration.IsActive) _orchestration.PrepareRemoteSetup();
        ((App)Application.Current).ShowOrchestrationWindow();
    }

    private void OnAddScriptClick(object sender, RoutedEventArgs e) => OpenScriptEditor(forNewScript: true);

    private void OpenScriptEditor(bool forNewScript)
    {
        _showOrchestrationConfiguration = false;
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
