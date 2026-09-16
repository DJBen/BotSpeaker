using System.Diagnostics;
using System.Windows.Threading;
using Velopack;
using Velopack.Sources;

namespace BotSpeaker;

/// <summary>UI-thread update coordinator. Downloading never implies restarting.</summary>
internal sealed class WindowsUpdater : IDisposable
{
    private readonly UpdateManager _manager;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromHours(6) };
    private readonly CancellationTokenSource _shutdown = new();
    private bool _disposed;
    private string? _notifiedVersion;

    public bool IsInstalled => _manager.IsInstalled;
    public bool IsBusy { get; private set; }
    public VelopackAsset? PendingUpdate { get; private set; }
    public event Action? Changed;
    public event Action<string>? UpdateReady;

    public WindowsUpdater(UpdateManager? manager = null)
    {
        _manager = manager ?? new UpdateManager(
            new GithubSource("https://github.com/DJBen/BotSpeaker", null, false));
        PendingUpdate = _manager.IsInstalled ? _manager.UpdatePendingRestart : null;
        _timer.Tick += OnTick;
    }

    public void Start()
    {
        if (!IsInstalled) return;
        _timer.Start();
        _ = CheckAsync(manual: false);
    }

    private async void OnTick(object? sender, EventArgs e) => await CheckAsync(manual: false);

    // Manual checks return a user-facing result; background failures are silent
    // and retried on the next interval. A single check/download runs at a time.
    public async Task<string?> CheckAsync(bool manual)
    {
        if (_disposed) return null;
        if (!IsInstalled)
            return "Automatic updates require the BotSpeaker Windows installer from GitHub Releases. "
                + "Portable ZIP and development builds must be updated manually.";
        if (IsBusy) return manual ? "An update check or download is already in progress." : null;

        IsBusy = true;
        Changed?.Invoke();
        try
        {
            var update = await _manager.CheckForUpdatesAsync();
            if (_disposed) return null;
            if (update is not null)
                await _manager.DownloadUpdatesAsync(update, cancelToken: _shutdown.Token);
            if (_disposed) return null;
            PendingUpdate = _manager.UpdatePendingRestart;
            if (PendingUpdate is { } pending)
            {
                var version = pending.Version.ToString();
                if (!manual && _notifiedVersion != version) UpdateReady?.Invoke(version);
                _notifiedVersion = version;
                return $"BotSpeaker {pending.Version} is ready. Choose 'Restart to update' in the tray menu when playback and meetings have ended.";
            }
            return manual ? "BotSpeaker is up to date." : null;
        }
        catch (Exception error)
        {
            Trace.TraceWarning("BotSpeaker update check failed: {0}", error);
            return manual && !_disposed ? $"Could not check for or download updates. Try again later.\n\n{error.Message}" : null;
        }
        finally
        {
            IsBusy = false;
            if (!_disposed) Changed?.Invoke();
        }
    }

    public void ApplyAndRestart()
    {
        if (IsBusy || PendingUpdate is not { } pending) return;
        // Let App shut down its control server and audio cleanly before replacement.
        _manager.WaitExitThenApplyUpdates(pending, restart: true);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _shutdown.Cancel();
        _timer.Stop();
        _timer.Tick -= OnTick;
    }
}
