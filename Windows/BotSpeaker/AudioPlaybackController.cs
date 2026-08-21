using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace BotSpeaker;

/// <summary>
/// Sequential chunk player: ElevenLabs MP3 chunks are decoded to 44.1 kHz mono float
/// samples and played through WASAPI on the selected render device (normally the
/// virtual cable). Supports append-while-generating, pause/stop/seek, looping,
/// volume and timing-based text progress — mirroring the macOS
/// AudioPlaybackController.
/// </summary>
public sealed class AudioPlaybackController : INotifyPropertyChanged
{
    private const int SampleRate = 44100;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Raised when playback reaches the end of a fully generated, non-looping sequence.</summary>
    public event Action? PlaybackFinished;

    private bool _isPlaying;
    public bool IsPlaying { get => _isPlaying; private set => Set(ref _isPlaying, value); }

    private bool _hasAudio;
    public bool HasAudio { get => _hasAudio; private set => Set(ref _hasAudio, value); }

    private double _currentTime;
    public double CurrentTime { get => _currentTime; private set => Set(ref _currentTime, value); }

    private double _duration;
    public double Duration { get => _duration; private set => Set(ref _duration, value); }

    private bool _isBuffering;
    public bool IsBuffering { get => _isBuffering; private set => Set(ref _isBuffering, value); }

    private int _generatedChunkCount;
    public int GeneratedChunkCount { get => _generatedChunkCount; private set => Set(ref _generatedChunkCount, value); }

    private int _totalChunkCount;
    public int TotalChunkCount { get => _totalChunkCount; private set => Set(ref _totalChunkCount, value); }

    private int _playedTextLength;
    public int PlayedTextLength { get => _playedTextLength; private set => Set(ref _playedTextLength, value); }

    private TextSpan? _activeTextRange;
    public TextSpan? ActiveTextRange { get => _activeTextRange; private set => Set(ref _activeTextRange, value); }

    public bool IsLooping { get; set; }

    private float _volume = 1;
    public float Volume
    {
        get => _volume;
        set => _volume = Math.Clamp(value, 0, 1);
    }

    private sealed class PlaybackChunk
    {
        public required float[] Samples { get; init; }
        public required SpeechTiming Timing { get; init; }
        public required TextSpan SourceRange { get; init; }
        public required long StartSample { get; init; }
        public double StartTime => (double)StartSample / SampleRate;
        public double DurationSeconds => (double)Samples.Length / SampleRate;
    }

    /// <summary>Pulls samples from the chunk list; shared state is guarded by <see cref="_gate"/>.</summary>
    private sealed class SequenceSampleProvider(AudioPlaybackController controller) : ISampleProvider
    {
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(SampleRate, 1);
        public int Read(float[] buffer, int offset, int count) => controller.ReadSamples(buffer, offset, count);
    }

    private readonly object _gate = new();
    private readonly List<PlaybackChunk> _chunks = [];
    private long _playCursor;
    private long _totalSamples;

    private WasapiOut? _output;
    private string _outputDeviceId = "";
    private int _stopGeneration;
    private bool _generationComplete = true;
    private bool _playRequested;
    private readonly DispatcherTimer _timer;

    public AudioPlaybackController()
    {
        _timer = new DispatcherTimer(DispatcherPriority.Normal) { Interval = TimeSpan.FromMilliseconds(100) };
        _timer.Tick += (_, _) => UpdateCurrentTime();
    }

    public void SelectOutputDevice(string deviceId)
    {
        using var device = AudioDeviceManager.Device(deviceId);
        if (device is null) throw new AppException("The selected audio device is no longer available.");

        bool shouldResume = _playRequested;
        DisposeOutput();
        _outputDeviceId = deviceId;
        if (HasAudio && shouldResume)
        {
            StartOutput();
        }
    }

    public void BeginSequence(int totalChunks, bool autoplay = true)
    {
        Reset();
        TotalChunkCount = totalChunks;
        _generationComplete = false;
        _playRequested = autoplay;
        IsBuffering = autoplay;
    }

    public void Append(string audioPath, SpeechTiming timing, TextSpan sourceRange)
    {
        var samples = DecodeToMono44100(audioPath);
        if (samples.Length == 0) throw new AppException("ElevenLabs returned an empty audio file.");

        lock (_gate)
        {
            _chunks.Add(new PlaybackChunk
            {
                Samples = samples,
                Timing = timing,
                SourceRange = sourceRange,
                StartSample = _totalSamples,
            });
            _totalSamples += samples.Length;
        }

        Duration = (double)_totalSamples / SampleRate;
        GeneratedChunkCount = _chunks.Count;
        HasAudio = true;

        if (_playRequested)
        {
            if (!IsPlaying)
            {
                StartOutput();
            }
        }
        UpdateTextProgress();
    }

    public void FinishSequence()
    {
        _generationComplete = true;
        TotalChunkCount = Math.Max(TotalChunkCount, GeneratedChunkCount);
        if (IsBuffering && _playCursor >= _totalSamples)
        {
            FinishPlayback();
        }
    }

    public void Reset()
    {
        DisposeOutput();
        lock (_gate)
        {
            _chunks.Clear();
            _playCursor = 0;
            _totalSamples = 0;
        }
        _generationComplete = true;
        _playRequested = false;
        IsPlaying = false;
        HasAudio = false;
        CurrentTime = 0;
        Duration = 0;
        IsBuffering = false;
        GeneratedChunkCount = 0;
        TotalChunkCount = 0;
        PlayedTextLength = 0;
        ActiveTextRange = null;
        _timer.Stop();
    }

    public void Play()
    {
        _playRequested = true;
        if (!HasAudio)
        {
            IsBuffering = !_generationComplete;
            return;
        }

        if (_playCursor >= _totalSamples)
        {
            if (_generationComplete)
            {
                Seek(0, resume: false);
            }
            else
            {
                IsBuffering = true;
                return;
            }
        }

        StartOutput();
    }

    public void Pause()
    {
        UpdateCurrentTime();
        _output?.Pause();
        _playRequested = false;
        IsBuffering = false;
        IsPlaying = false;
        _timer.Stop();
    }

    public void Stop()
    {
        DisposeOutput();
        lock (_gate) { _playCursor = 0; }
        CurrentTime = 0;
        _playRequested = false;
        IsBuffering = false;
        IsPlaying = false;
        _timer.Stop();
        UpdateTextProgress();
    }

    public void Seek(double seconds) => Seek(seconds, _playRequested);

    private void Seek(double seconds, bool resume)
    {
        if (!HasAudio) return;
        var clamped = Math.Clamp(seconds, 0, Duration);
        lock (_gate)
        {
            _playCursor = Math.Min((long)(clamped * SampleRate), _totalSamples);
        }
        CurrentTime = clamped;
        UpdateTextProgress();
        // The WASAPI buffer already holds pre-seek samples; restart the output so the
        // jump is immediate.
        bool wasPlaying = IsPlaying;
        DisposeOutput();
        IsPlaying = false;
        _timer.Stop();

        if (resume)
        {
            _playRequested = true;
            if (_playCursor >= _totalSamples && !_generationComplete)
            {
                IsBuffering = true;
            }
            else if (_playCursor < _totalSamples)
            {
                Play();
            }
        }
        else
        {
            _playRequested = false;
            IsBuffering = false;
            _ = wasPlaying;
        }
    }

    private int ReadSamples(float[] buffer, int offset, int count)
    {
        lock (_gate)
        {
            int written = 0;
            float volume = _volume;
            while (written < count && _playCursor < _totalSamples)
            {
                var chunk = FindChunkLocked(_playCursor);
                if (chunk is null) break;
                int chunkOffset = (int)(_playCursor - chunk.StartSample);
                int available = chunk.Samples.Length - chunkOffset;
                int toCopy = Math.Min(available, count - written);
                for (int i = 0; i < toCopy; i++)
                {
                    buffer[offset + written + i] = chunk.Samples[chunkOffset + i] * volume;
                }
                written += toCopy;
                _playCursor += toCopy;
            }
            return written;
        }
    }

    private PlaybackChunk? FindChunkLocked(long sample)
    {
        foreach (var chunk in _chunks)
        {
            if (sample >= chunk.StartSample && sample < chunk.StartSample + chunk.Samples.Length) return chunk;
        }
        return null;
    }

    private void StartOutput()
    {
        try
        {
            if (_output is null)
            {
                using var device = AudioDeviceManager.Device(_outputDeviceId)
                    ?? throw new AppException("The selected audio device is no longer available.");
                var output = new WasapiOut(device, AudioClientShareMode.Shared, useEventSync: true, latency: 100);
                int generation = ++_stopGeneration;
                output.PlaybackStopped += (_, _) => OnPlaybackStopped(generation);
                output.Init(new SequenceSampleProvider(this));
                _output = output;
            }
            _output.Play();
            IsPlaying = true;
            IsBuffering = false;
            _timer.Start();
        }
        catch (Exception)
        {
            IsPlaying = false;
            _timer.Stop();
        }
    }

    private void OnPlaybackStopped(int generation)
    {
        if (generation != _stopGeneration) return;
        DisposeOutput();
        IsPlaying = false;
        _timer.Stop();

        if (_playCursor >= _totalSamples)
        {
            if (_generationComplete)
            {
                FinishPlayback();
                if (IsLooping)
                {
                    Seek(0, resume: true);
                }
            }
            else
            {
                // Generation is still running; resume automatically when the next chunk lands.
                IsBuffering = _playRequested;
            }
        }
        UpdateTextProgress();
    }

    private void FinishPlayback()
    {
        CurrentTime = Duration;
        IsPlaying = false;
        IsBuffering = false;
        _playRequested = false;
        _timer.Stop();
        UpdateTextProgress();
        if (!IsLooping) PlaybackFinished?.Invoke();
    }

    private void DisposeOutput()
    {
        _stopGeneration++;
        if (_output is not null)
        {
            var output = _output;
            _output = null;
            try { output.Stop(); } catch (Exception) { }
            output.Dispose();
        }
    }

    private void UpdateCurrentTime()
    {
        long cursor;
        lock (_gate) { cursor = _playCursor; }
        CurrentTime = Math.Min((double)cursor / SampleRate, Duration);
        UpdateTextProgress();
    }

    private void UpdateTextProgress()
    {
        PlaybackChunk? current;
        List<PlaybackChunk> chunksSnapshot;
        lock (_gate)
        {
            if (_chunks.Count == 0)
            {
                PlayedTextLength = 0;
                ActiveTextRange = null;
                return;
            }
            chunksSnapshot = [.. _chunks];
            current = FindChunkLocked(Math.Min(_playCursor, Math.Max(_totalSamples - 1, 0)));
        }

        if (current is null || _playCursor >= _totalSamples && _generationComplete)
        {
            PlayedTextLength = chunksSnapshot.Max(c => c.SourceRange.End);
            ActiveTextRange = null;
            return;
        }

        double localTime = Math.Max(CurrentTime - current.StartTime, 0);
        int previousEnd = chunksSnapshot
            .Where(c => c.StartSample < current.StartSample)
            .Select(c => c.SourceRange.End)
            .DefaultIfEmpty(0)
            .Max();
        int localOffset = Math.Min(current.Timing.PlayedUtf16Offset(localTime), current.SourceRange.Length);
        PlayedTextLength = Math.Max(previousEnd, current.SourceRange.Location + localOffset);

        var span = current.Timing.SentenceSpans.FirstOrDefault(s => localTime >= s.StartTime && localTime < s.EndTime)
            ?? current.Timing.SentenceSpans.FirstOrDefault(s => localTime < s.EndTime);

        if (span is not null)
        {
            int location = current.SourceRange.Location + Math.Min(span.Location, current.SourceRange.Length);
            int availableLength = Math.Max(current.SourceRange.End - location, 0);
            ActiveTextRange = new TextSpan(location, Math.Min(span.Length, availableLength));
        }
        else
        {
            ActiveTextRange = current.SourceRange;
        }
    }

    private static float[] DecodeToMono44100(string path)
    {
        using var reader = new AudioFileReader(path);
        ISampleProvider provider = reader;
        if (provider.WaveFormat.Channels > 1)
        {
            provider = new StereoToMonoSampleProvider(provider)
            {
                LeftVolume = 0.5f,
                RightVolume = 0.5f,
            };
        }
        if (provider.WaveFormat.SampleRate != SampleRate)
        {
            provider = new WdlResamplingSampleProvider(provider, SampleRate);
        }

        var samples = new List<float>(capacity: (int)(reader.Length / 4));
        var buffer = new float[SampleRate];
        int read;
        while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
        {
            for (int i = 0; i < read; i++) samples.Add(buffer[i]);
        }
        return [.. samples];
    }

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
