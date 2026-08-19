using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace BotSpeaker;

/// <summary>Application state and orchestration — the Windows counterpart of the macOS AppModel.</summary>
public sealed class AppModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    private string _text = "";
    public string Text { get => _text; private set => Set(ref _text, value); }

    private string _selectedScriptId = "";
    public string SelectedScriptId { get => _selectedScriptId; private set => Set(ref _selectedScriptId, value); }

    private bool _isGenerating;
    public bool IsGenerating { get => _isGenerating; private set => Set(ref _isGenerating, value); }

    private string? _errorMessage;
    public string? ErrorMessage { get => _errorMessage; set => Set(ref _errorMessage, value); }

    private bool _hasApiKey;
    public bool HasApiKey { get => _hasApiKey; private set => Set(ref _hasApiKey, value); }

    private List<ElevenLabsVoice> _voices = [];
    public List<ElevenLabsVoice> Voices { get => _voices; private set => Set(ref _voices, value); }

    private bool _isLoadingVoices;
    public bool IsLoadingVoices { get => _isLoadingVoices; private set => Set(ref _isLoadingVoices, value); }

    private string? _voiceLoadError;
    public string? VoiceLoadError { get => _voiceLoadError; private set => Set(ref _voiceLoadError, value); }

    public AudioPlaybackController Player { get; } = new();
    public AudioDeviceManager Devices { get; } = new();
    public InterruptionMonitor InterruptionMonitor { get; } = new();
    public List<CustomSpeechScript> CustomScripts => Settings.CustomScripts;

    public readonly AppSettings Settings;
    private readonly CredentialStore _credentials = new();
    private readonly ElevenLabsClient _client = new();
    private CancellationTokenSource? _generationCancellation;
    private Guid _generationId = Guid.NewGuid();
    private string? _currentSpeechSignature;

    public List<SpeechScript> BundledScripts { get; } =
        ExampleExcerpt.All.Select(e => e.SpeechScript).ToList();

    public IReadOnlyList<ExampleScenario> BundledScriptGroups => ExampleExcerpt.Scenarios;

    public List<SpeechScript> AvailableScripts =>
        BundledScripts.Concat(CustomScripts.Select(c =>
            new SpeechScript($"custom:{c.Id}", c.Title, c.Detail ?? "Custom script", c.Text, c.Id))).ToList();

    /// <summary>Built-in scripts are role templates; only named copies are playable.</summary>
    public List<SpeechScript> PlayableScripts => AvailableScripts.Where(s => s.IsCustom).ToList();

    public SpeechScript SelectedScript =>
        AvailableScripts.FirstOrDefault(s => s.Id == SelectedScriptId) ?? BundledScripts[0];

    public string VoiceId
    {
        get => Settings.VoiceId;
        set { Settings.VoiceId = value; Settings.Save(); Notify(); Notify(nameof(SelectedVoiceName)); }
    }

    public string ModelId
    {
        get => Settings.ModelId;
        set { Settings.ModelId = value; Settings.Save(); Notify(); }
    }

    public string SelectedDeviceId
    {
        get => Settings.OutputDeviceId;
        set
        {
            Settings.OutputDeviceId = value;
            Settings.Save();
            Notify();
            Notify(nameof(SelectedDeviceName));
            try { Player.SelectOutputDevice(value); } catch (AppException) { }
        }
    }

    public bool LoopEnabled
    {
        get => Settings.LoopEnabled;
        set { Settings.LoopEnabled = value; Settings.Save(); Player.IsLooping = value; Notify(); }
    }

    public double OutputVolume
    {
        get => Settings.OutputVolume;
        set
        {
            Settings.OutputVolume = Math.Clamp(value, 0, 1);
            Settings.Save();
            Player.Volume = (float)Settings.OutputVolume;
            Notify();
        }
    }

    public bool InterruptionEnabled
    {
        get => Settings.InterruptionEnabled;
        set
        {
            Settings.InterruptionEnabled = value;
            Settings.Save();
            Notify();
            if (value)
            {
                InterruptionMonitor.Start(InterruptionInputId);
            }
            else
            {
                InterruptionMonitor.Stop();
                Player.SetInterruptionActive(false);
            }
        }
    }

    public string InterruptionInputId
    {
        get => string.IsNullOrEmpty(Settings.InterruptionInputId)
            ? AudioDeviceManager.DefaultInputDeviceId() ?? ""
            : Settings.InterruptionInputId;
        set
        {
            Settings.InterruptionInputId = value;
            Settings.Save();
            Notify();
            if (InterruptionEnabled) InterruptionMonitor.Start(value);
        }
    }

    public string SelectedVoiceName =>
        Voices.FirstOrDefault(v => v.Id == VoiceId)?.Name
        ?? $"Voice ID {VoiceId[..Math.Min(8, VoiceId.Length)]}…";

    public string SelectedDeviceName =>
        Devices.OutputDevices.FirstOrDefault(d => d.Id == SelectedDeviceId)?.Name ?? "Output unavailable";

    public bool SelectedDeviceAvailable => Devices.OutputDevices.Any(d => d.Id == SelectedDeviceId);

    public AppModel()
    {
        Settings = AppSettings.Load();

        var requestedId = string.IsNullOrEmpty(Settings.SelectedScriptId)
            ? BundledScripts[0].Id
            : Settings.SelectedScriptId;
        var initialScript = AvailableScripts.FirstOrDefault(s => s.Id == requestedId) ?? BundledScripts[0];
        _selectedScriptId = initialScript.Id;
        _text = initialScript.Text;
        if (initialScript.IsCustom)
        {
            Settings.LastPlayableScriptId = initialScript.Id;
            Settings.Save();
        }

        HasApiKey = !string.IsNullOrEmpty(_credentials.Read());
        Player.IsLooping = Settings.LoopEnabled;
        Player.Volume = (float)Settings.OutputVolume;
        Devices.Refresh();
        InterruptionMonitor.OnActivityChanged = active => Player.SetInterruptionActive(active);

        if (string.IsNullOrEmpty(SelectedDeviceId))
        {
            var cable = Devices.OutputDevices.FirstOrDefault(d => d.IsVirtualCable);
            if (cable is not null) SelectedDeviceId = cable.Id;
        }
        else
        {
            try { Player.SelectOutputDevice(SelectedDeviceId); } catch (AppException) { }
        }

        if (InterruptionEnabled)
        {
            InterruptionMonitor.Start(InterruptionInputId);
        }
    }

    public void SaveApiKey(string key)
    {
        var trimmed = key.Trim();
        if (trimmed.Length == 0) throw new AppException("Enter an ElevenLabs API key.");
        _credentials.Save(trimmed);
        HasApiKey = true;
    }

    public async Task ValidateAndSaveApiKeyAsync(string key)
    {
        var trimmed = key.Trim();
        if (trimmed.Length == 0) throw new AppException("Enter an ElevenLabs API key.");
        await _client.ValidateAsync(trimmed);
        SaveApiKey(trimmed);
        await RefreshVoicesAsync();
    }

    public void RemoveApiKey()
    {
        _credentials.Delete();
        HasApiKey = false;
        Voices = [];
        VoiceLoadError = null;
    }

    public async Task LoadVoicesIfNeededAsync()
    {
        if (Voices.Count > 0 || IsLoadingVoices) return;
        await RefreshVoicesAsync();
    }

    public async Task RefreshVoicesAsync()
    {
        var apiKey = _credentials.Read();
        if (string.IsNullOrEmpty(apiKey))
        {
            Voices = [];
            VoiceLoadError = "Add an ElevenLabs API key to load voices.";
            return;
        }

        IsLoadingVoices = true;
        VoiceLoadError = null;
        try
        {
            Voices = await _client.ListVoicesAsync(apiKey);
            if (Voices.Count == 0) VoiceLoadError = "No voices are available for this ElevenLabs account.";
        }
        catch (Exception error)
        {
            VoiceLoadError = error.Message;
        }
        finally
        {
            IsLoadingVoices = false;
            Notify(nameof(SelectedVoiceName));
        }
    }

    public void SelectScript(string id)
    {
        if (id == SelectedScriptId) return;
        var script = AvailableScripts.FirstOrDefault(s => s.Id == id);
        if (script is null) return;
        CancelGeneration(resetPlayer: true);
        _currentSpeechSignature = null;
        ErrorMessage = null;
        SelectedScriptId = script.Id;
        Text = script.Text;
        Settings.SelectedScriptId = script.Id;
        if (script.IsCustom)
        {
            Settings.LastPlayableScriptId = script.Id;
        }
        Settings.Save();
        Notify(nameof(SelectedScript));
    }

    public void DeleteCustomScript(Guid id)
    {
        var index = CustomScripts.FindIndex(c => c.Id == id);
        if (index < 0) return;
        var scriptId = $"custom:{id}";
        bool wasSelected = SelectedScriptId == scriptId;

        if (wasSelected)
        {
            CancelGeneration(resetPlayer: true);
            _currentSpeechSignature = null;
            ErrorMessage = null;
        }
        CustomScripts.RemoveAt(index);

        if (Settings.LastPlayableScriptId == scriptId)
        {
            Settings.LastPlayableScriptId = CustomScripts.Count > 0
                ? $"custom:{CustomScripts[0].Id}"
                : "";
        }
        Settings.Save();

        if (wasSelected)
        {
            var fallback = CustomScripts.Count > 0
                ? $"custom:{CustomScripts[0].Id}"
                : BundledScripts[0].Id;
            SelectScript(fallback);
        }
        Notify(nameof(AvailableScripts));
    }

    /// <summary>
    /// Creates a durable custom script from a built-in role template. Name
    /// substitution happens here once; later playback does not depend on the
    /// name field and receives its own cache namespace.
    /// </summary>
    public void CreateNamedScriptFromSelectedTemplate(string speakerName)
    {
        var template = SelectedScript;
        if (template.IsCustom)
        {
            throw new AppException("Choose a role template first.");
        }
        var name = speakerName.Trim();
        if (name.Length == 0) throw new AppException("Enter the speaker's name.");

        var resolvedText = template.Text.Replace(ExampleExcerpt.NamePlaceholder, name);
        if (resolvedText == template.Text)
        {
            throw new AppException("This template does not contain a name placeholder.");
        }

        var script = new CustomSpeechScript
        {
            Title = $"{name} — {template.Title}",
            Text = resolvedText,
            Detail = template.Detail,
        };
        CustomScripts.Add(script);
        Settings.Save();
        SelectScript($"custom:{script.Id}");
        Notify(nameof(AvailableScripts));
    }

    public SpeechScript SaveCustomScript(Guid? editingId, string title, string text)
    {
        title = title.Trim();
        text = text.Trim();
        if (title.Length == 0) throw new AppException("Give this script a name.");
        if (text.Length == 0) throw new AppException("Add some text to the script.");

        Guid id;
        if (editingId is Guid existing && CustomScripts.FirstOrDefault(c => c.Id == existing) is CustomSpeechScript found)
        {
            id = existing;
            found.Title = title;
            found.Text = text;
        }
        else
        {
            var script = new CustomSpeechScript { Title = title, Text = text };
            id = script.Id;
            CustomScripts.Add(script);
        }
        Settings.Save();

        var scriptId = $"custom:{id}";
        if (scriptId == SelectedScriptId)
        {
            CancelGeneration(resetPlayer: true);
            _currentSpeechSignature = null;
            Text = text;
            ErrorMessage = null;
            Notify(nameof(SelectedScript));
        }
        else
        {
            SelectScript(scriptId);
        }
        Notify(nameof(AvailableScripts));
        return SelectedScript;
    }

    public async Task PrimaryActionAsync() => await GenerateOrToggleAsync(forceRegenerate: false);

    public async Task RegenerateAsync() => await GenerateOrToggleAsync(forceRegenerate: true);

    private async Task GenerateOrToggleAsync(bool forceRegenerate)
    {
        ErrorMessage = null;
        var trimmed = Text.Trim();
        if (trimmed.Length == 0)
        {
            ErrorMessage = "Paste some text first.";
            return;
        }

        var script = SelectedScript;
        if (!script.IsCustom)
        {
            // Guards the tray Play item and hotkey; the composer hides playback for templates.
            ErrorMessage = "Create a named script from this template before playback.";
            return;
        }
        var signature = $"{script.Id}|{VoiceId}|{ModelId}|{trimmed}";
        if (!forceRegenerate && _currentSpeechSignature == signature && (Player.HasAudio || IsGenerating))
        {
            if (Player.IsPlaying || Player.IsBuffering || Player.IsWaitingForInterruption)
            {
                Player.Pause();
            }
            else
            {
                Player.Play();
            }
            return;
        }

        var apiKey = _credentials.Read();
        if (string.IsNullOrEmpty(apiKey))
        {
            HasApiKey = false;
            ErrorMessage = "Add your ElevenLabs API key in Settings.";
            return;
        }

        if (string.IsNullOrEmpty(SelectedDeviceId))
        {
            ErrorMessage = "Choose an audio output in Settings.";
            return;
        }

        var plans = SpeechTextChunker.Chunks(Text);
        if (plans.Count == 0)
        {
            ErrorMessage = "Paste some text first.";
            return;
        }

        try
        {
            CancelGeneration(resetPlayer: false);
            Player.SelectOutputDevice(SelectedDeviceId);
            Player.IsLooping = LoopEnabled;
            Player.BeginSequence(plans.Count);
            _currentSpeechSignature = signature;
            IsGenerating = true;

            var taskId = Guid.NewGuid();
            _generationId = taskId;
            var cancellation = new CancellationTokenSource();
            _generationCancellation = cancellation;
            await GenerateSequentiallyAsync(
                plans, VoiceId, ModelId, apiKey, script.CacheNamespace, forceRegenerate, taskId, cancellation.Token);
        }
        catch (AppException error)
        {
            ErrorMessage = error.Message;
            IsGenerating = false;
        }
    }

    public void StopPlayback()
    {
        CancelGeneration(resetPlayer: false);
        Player.FinishSequence();
        Player.Stop();
        _currentSpeechSignature = null;
    }

    private async Task GenerateSequentiallyAsync(
        List<SpeechChunkPlan> plans,
        string voiceId,
        string modelId,
        string apiKey,
        string cacheNamespace,
        bool bypassCache,
        Guid taskId,
        CancellationToken cancellation)
    {
        try
        {
            foreach (var plan in plans)
            {
                cancellation.ThrowIfCancellationRequested();
                var clip = await _client.SynthesizeAsync(
                    plan.Text, voiceId, modelId, apiKey,
                    plan.PreviousText, plan.NextText,
                    cacheNamespace, bypassCache, cancellation);
                cancellation.ThrowIfCancellationRequested();
                if (_generationId != taskId) return;
                Player.Append(clip.AudioPath, clip.Timing, plan.SourceRange);
            }
            if (_generationId != taskId) return;
            Player.FinishSequence();
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            if (_generationId != taskId) return;
            Player.FinishSequence();
            ErrorMessage = Player.GeneratedChunkCount > 0
                ? $"Generation stopped after {Player.GeneratedChunkCount} of {plans.Count} sections: {error.Message}"
                : error.Message;
        }
        finally
        {
            if (_generationId == taskId)
            {
                IsGenerating = false;
                _generationCancellation = null;
            }
        }
    }

    private void CancelGeneration(bool resetPlayer)
    {
        _generationCancellation?.Cancel();
        _generationCancellation = null;
        _generationId = Guid.NewGuid();
        IsGenerating = false;
        if (resetPlayer) Player.Reset();
    }

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        Notify(name);
    }

    private void Notify([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
