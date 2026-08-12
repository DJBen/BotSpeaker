using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace BotSpeaker;

/// <summary>
/// Adaptive interruption detection: learns the monitored input's ambient level,
/// flags activity when a 0.4 s rolling window stays above an adaptive threshold,
/// and clears it after 0.75 s continuously near ambient — same tuning as the
/// macOS InterruptionMonitor.
/// </summary>
public sealed class InterruptionMonitor : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    private bool _isMonitoring;
    public bool IsMonitoring { get => _isMonitoring; private set => Set(ref _isMonitoring, value); }

    private bool _isHearingAudio;
    public bool IsHearingAudio { get => _isHearingAudio; private set => Set(ref _isHearingAudio, value); }

    private string? _errorMessage;
    public string? ErrorMessage { get => _errorMessage; private set => Set(ref _errorMessage, value); }

    public Action<bool>? OnActivityChanged { get; set; }

    private WasapiCapture? _capture;
    private double? _monitoringStartedAt;
    private readonly List<float> _calibrationLevels = [];
    private float? _ambientEstimateDb;
    private double? _activityWindowStartedAt;
    private readonly List<float> _activityLevels = [];
    private double? _ambientWindowStartedAt;
    private readonly List<float> _ambientReturnLevels = [];

    private const double CalibrationDuration = 0.75;
    private const double ActivityWindowDuration = 0.4;
    private const double AmbientReturnWindowDuration = 0.75;
    private const float ActivityMarginDb = 10;
    private const float AmbientReturnMarginDb = 4;
    private const float MinimumActivityThresholdDb = -45;
    private const float MaximumActivityThresholdDb = -18;
    private const float AmbientSmoothing = 0.04f;

    private static readonly Guid IeeeFloatSubFormat = new("00000003-0000-0010-8000-00aa00389b71");

    public void Start(string inputId)
    {
        Stop(clearError: false);
        ErrorMessage = null;

        try
        {
            var device = AudioDeviceManager.Device(
                string.IsNullOrEmpty(inputId) ? AudioDeviceManager.DefaultInputDeviceId() ?? "" : inputId)
                ?? throw new AppException("The interruption input is unavailable.");

            var capture = new WasapiCapture(device);
            capture.DataAvailable += OnDataAvailable;
            capture.RecordingStopped += (_, _) => device.Dispose();
            _capture = capture;
            _monitoringStartedAt = Now();
            capture.StartRecording();
            IsMonitoring = true;
        }
        catch (Exception error)
        {
            Stop(clearError: false);
            ErrorMessage = error.Message;
        }
    }

    public void Stop(bool clearError = true)
    {
        if (_capture is not null)
        {
            var capture = _capture;
            _capture = null;
            capture.DataAvailable -= OnDataAvailable;
            try { capture.StopRecording(); } catch (Exception) { }
            capture.Dispose();
        }
        _monitoringStartedAt = null;
        _calibrationLevels.Clear();
        _ambientEstimateDb = null;
        _activityWindowStartedAt = null;
        _activityLevels.Clear();
        _ambientWindowStartedAt = null;
        _ambientReturnLevels.Clear();
        IsMonitoring = false;
        SetHearingAudio(false);
        if (clearError) ErrorMessage = null;
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs args)
    {
        var format = (sender as WasapiCapture)?.WaveFormat;
        if (format is null || args.BytesRecorded == 0) return;

        double sum = 0;
        int sampleCount = 0;

        bool isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat
            || (format is WaveFormatExtensible extensible && extensible.SubFormat == IeeeFloatSubFormat);
        if (isFloat)
        {
            for (int i = 0; i + 4 <= args.BytesRecorded; i += 4)
            {
                float value = BitConverter.ToSingle(args.Buffer, i);
                sum += value * value;
                sampleCount++;
            }
        }
        else if (format.BitsPerSample == 16)
        {
            for (int i = 0; i + 2 <= args.BytesRecorded; i += 2)
            {
                float value = BitConverter.ToInt16(args.Buffer, i) / 32768f;
                sum += value * value;
                sampleCount++;
            }
        }
        else
        {
            return;
        }

        if (sampleCount == 0) return;
        float rms = (float)Math.Sqrt(sum / sampleCount);
        float decibels = 20f * (float)Math.Log10(Math.Max(rms, 0.0000001f));
        Application.Current?.Dispatcher.BeginInvoke(() => Receive(decibels));
    }

    private static double Now() => Environment.TickCount64 / 1000.0;

    private void Receive(float decibels)
    {
        double now = Now();
        if (_monitoringStartedAt is not double startedAt) return;

        if (now - startedAt < CalibrationDuration)
        {
            _calibrationLevels.Add(decibels);
            _ambientEstimateDb = Percentile(_calibrationLevels, 0.3);
            return;
        }

        _ambientEstimateDb ??= decibels;
        float ambient = _ambientEstimateDb.Value;
        float activityThreshold = Math.Min(
            Math.Max(ambient + ActivityMarginDb, MinimumActivityThresholdDb),
            MaximumActivityThresholdDb);

        if (IsHearingAudio)
        {
            CollectAmbientReturn(decibels, now, ambient);
        }
        else
        {
            CollectPossibleActivity(decibels, now, activityThreshold);
            if (_activityWindowStartedAt is null && decibels < activityThreshold)
            {
                _ambientEstimateDb = ambient + (decibels - ambient) * AmbientSmoothing;
            }
        }
    }

    private void CollectPossibleActivity(float decibels, double now, float threshold)
    {
        if (_activityWindowStartedAt is not double startedAt)
        {
            if (decibels >= threshold)
            {
                _activityWindowStartedAt = now;
                _activityLevels.Clear();
                _activityLevels.Add(decibels);
            }
            return;
        }

        _activityLevels.Add(decibels);
        if (now - startedAt < ActivityWindowDuration) return;

        if (AveragePowerDb(_activityLevels) >= threshold)
        {
            _activityWindowStartedAt = null;
            _activityLevels.Clear();
            _ambientWindowStartedAt = null;
            _ambientReturnLevels.Clear();
            SetHearingAudio(true);
        }
        else if (decibels >= threshold)
        {
            _activityWindowStartedAt = now;
            _activityLevels.Clear();
            _activityLevels.Add(decibels);
        }
        else
        {
            _activityWindowStartedAt = null;
            _activityLevels.Clear();
        }
    }

    private void CollectAmbientReturn(float decibels, double now, float ambient)
    {
        float returnThreshold = ambient + AmbientReturnMarginDb;
        if (decibels > returnThreshold)
        {
            _ambientWindowStartedAt = null;
            _ambientReturnLevels.Clear();
            return;
        }

        if (_ambientWindowStartedAt is not double startedAt)
        {
            _ambientWindowStartedAt = now;
            _ambientReturnLevels.Clear();
            _ambientReturnLevels.Add(decibels);
            return;
        }

        _ambientReturnLevels.Add(decibels);
        if (now - startedAt < AmbientReturnWindowDuration) return;
        if (AveragePowerDb(_ambientReturnLevels) > returnThreshold) return;

        float returnedAmbient = AveragePowerDb(_ambientReturnLevels);
        _ambientEstimateDb = ambient + (returnedAmbient - ambient) * 0.2f;
        _ambientWindowStartedAt = null;
        _ambientReturnLevels.Clear();
        _activityWindowStartedAt = null;
        _activityLevels.Clear();
        SetHearingAudio(false);
    }

    private static float AveragePowerDb(List<float> levels)
    {
        if (levels.Count == 0) return -160;
        double meanPower = levels.Average(db => Math.Pow(10, db / 10.0));
        return 10f * (float)Math.Log10(Math.Max(meanPower, 1e-16));
    }

    private static float? Percentile(List<float> levels, double fraction)
    {
        if (levels.Count == 0) return null;
        var sorted = levels.Order().ToList();
        int index = Math.Min((int)((sorted.Count - 1) * fraction), sorted.Count - 1);
        return sorted[index];
    }

    private void SetHearingAudio(bool value)
    {
        if (IsHearingAudio == value) return;
        IsHearingAudio = value;
        OnActivityChanged?.Invoke(value);
    }

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
