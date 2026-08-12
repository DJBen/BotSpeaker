using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Navigation;

namespace BotSpeaker;

public partial class SettingsWindow : Window
{
    private readonly AppModel _model;
    private bool _suppressUiEvents;

    public SettingsWindow(AppModel model)
    {
        _model = model;
        InitializeComponent();
        _model.PropertyChanged += OnModelChanged;
        _model.InterruptionMonitor.PropertyChanged += OnModelChanged;
        Loaded += async (_, _) =>
        {
            UpdateAll();
            await _model.LoadVoicesIfNeededAsync();
        };
        Closing += (_, e) =>
        {
            e.Cancel = true;
            Hide();
        };
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) =>
        Dispatcher.BeginInvoke(UpdateAll);

    private void UpdateAll()
    {
        _suppressUiEvents = true;
        try
        {
            SaveKeyButton.Content = _model.HasApiKey ? "Replace Key" : "Save Key";
            KeySavedLabel.Visibility = _model.HasApiKey ? Visibility.Visible : Visibility.Collapsed;
            RemoveKeyButton.Visibility = _model.HasApiKey ? Visibility.Visible : Visibility.Collapsed;

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

            if (!VoiceIdBox.IsFocused) VoiceIdBox.Text = _model.VoiceId;
            if (!ModelIdBox.IsFocused) ModelIdBox.Text = _model.ModelId;

            var outputs = _model.Devices.OutputDevices;
            OutputCombo.ItemsSource = new[] { "Choose an output…" }
                .Concat(outputs.Select(d => d.IsVirtualCable ? $"{d.Name} — recommended" : d.Name))
                .ToList();
            OutputCombo.SelectedIndex = outputs.FindIndex(d => d.Id == _model.SelectedDeviceId) + 1;

            var inputs = _model.Devices.InputDevices;
            InputCombo.ItemsSource = inputs.Select(d => d.Name).ToList();
            InputCombo.SelectedIndex = inputs.FindIndex(d => d.Id == _model.InterruptionInputId);

            InterruptionError.Text = _model.InterruptionMonitor.ErrorMessage ?? "";
            InterruptionError.Visibility = _model.InterruptionMonitor.ErrorMessage is null
                ? Visibility.Collapsed : Visibility.Visible;
        }
        finally
        {
            _suppressUiEvents = false;
        }
    }

    private async void OnSaveKeyClick(object sender, RoutedEventArgs e)
    {
        SaveKeyButton.IsEnabled = false;
        ShowFeedback(null);
        try
        {
            await _model.ValidateAndSaveApiKeyAsync(KeyBox.Password);
            KeyBox.Clear();
            ShowFeedback("API key validated and saved.");
        }
        catch (Exception error)
        {
            ShowFeedback(error.Message);
        }
        finally
        {
            SaveKeyButton.IsEnabled = true;
        }
    }

    private void OnRemoveKeyClick(object sender, RoutedEventArgs e)
    {
        _model.RemoveApiKey();
        ShowFeedback("API key removed.");
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

    private void OnVoiceIdChanged(object sender, RoutedEventArgs e)
    {
        if (!_suppressUiEvents && VoiceIdBox.Text != _model.VoiceId) _model.VoiceId = VoiceIdBox.Text;
    }

    private void OnModelIdChanged(object sender, RoutedEventArgs e)
    {
        if (!_suppressUiEvents && ModelIdBox.Text != _model.ModelId) _model.ModelId = ModelIdBox.Text;
    }

    private void OnOutputSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressUiEvents) return;
        var outputs = _model.Devices.OutputDevices;
        int index = OutputCombo.SelectedIndex - 1;
        if (index >= 0 && index < outputs.Count && outputs[index].Id != _model.SelectedDeviceId)
        {
            _model.SelectedDeviceId = outputs[index].Id;
        }
    }

    private void OnInputSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressUiEvents) return;
        var inputs = _model.Devices.InputDevices;
        int index = InputCombo.SelectedIndex;
        if (index >= 0 && index < inputs.Count && inputs[index].Id != _model.InterruptionInputId)
        {
            _model.InterruptionInputId = inputs[index].Id;
        }
    }

    private void OnRefreshDevicesClick(object sender, RoutedEventArgs e)
    {
        _model.Devices.Refresh();
        UpdateAll();
    }

    private void ShowFeedback(string? message)
    {
        Feedback.Text = message ?? "";
        Feedback.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnLinkNavigate(object sender, RequestNavigateEventArgs e)
    {
        Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
        e.Handled = true;
    }
}
