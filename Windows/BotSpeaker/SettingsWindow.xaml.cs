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
            KeyStatusLabel.Text = _model.HasApiKey
                ? "🛡 API key saved (DPAPI encrypted)"
                : "🔑 API key not configured";
            EditKeyButton.Content = _model.HasApiKey ? "Replace API Key…" : "Add API Key…";
            KeyPopupHeading.Text = _model.HasApiKey ? "Replace ElevenLabs API Key" : "Add ElevenLabs API Key";
            RemoveKeyButton.Visibility = _model.HasApiKey ? Visibility.Visible : Visibility.Collapsed;

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

    private void OnEditKeyClick(object sender, RoutedEventArgs e)
    {
        KeyBox.Clear();
        SetKeyPopupError(null);
        KeyPopup.IsOpen = true;
    }

    private void OnKeyPopupOpened(object sender, EventArgs e) => KeyBox.Focus();

    private void OnKeyPopupCancel(object sender, RoutedEventArgs e)
    {
        KeyBox.Clear();
        KeyPopup.IsOpen = false;
    }

    private async void OnSaveKeyClick(object sender, RoutedEventArgs e)
    {
        SaveKeyButton.IsEnabled = false;
        SaveKeyButton.Content = "Validating…";
        SetKeyPopupError(null);
        try
        {
            await _model.ValidateAndSaveApiKeyAsync(KeyBox.Password);
            KeyBox.Clear();
            KeyPopup.IsOpen = false;
            ShowFeedback("API key validated and saved.");
        }
        catch (Exception error)
        {
            SetKeyPopupError(error.Message);
        }
        finally
        {
            SaveKeyButton.IsEnabled = true;
            SaveKeyButton.Content = "Save Key";
        }
    }

    private void OnRemoveKeyClick(object sender, RoutedEventArgs e)
    {
        _model.RemoveApiKey();
        KeyBox.Clear();
        KeyPopup.IsOpen = false;
        ShowFeedback("API key removed.");
    }

    private void SetKeyPopupError(string? message)
    {
        KeyPopupError.Text = message ?? "";
        KeyPopupError.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
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
