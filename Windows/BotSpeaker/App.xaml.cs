using System.IO;
using System.Windows;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace BotSpeaker;

public partial class App : Application
{
    public AppModel Model { get; private set; } = null!;
    public OrchestrationController Orchestration { get; private set; } = null!;
    private MainWindow? _mainWindow;
    private Forms.NotifyIcon? _trayIcon;
    private Forms.ToolStripMenuItem? _playPauseItem;
    private Drawing.Icon? _appIcon;
    private ControlServer? _controlServer;
    private WindowsUpdater? _updater;
    private Forms.ToolStripMenuItem? _checkUpdateItem;
    private Forms.ToolStripMenuItem? _restartUpdateItem;
    private bool _exitRequested;
    public bool IsShuttingDown { get; private set; }

    [STAThread]
    public static void Main()
    {
        // Installer hooks must run before any WPF, audio, or control API startup.
        // Explicit restart also prevents a second launch from interrupting a meeting.
        Velopack.VelopackApp.Build().SetAutoApplyOnStartup(false)
            .OnAfterInstallFastCallback(_ => CliPath.Register())
            .OnAfterUpdateFastCallback(_ => CliPath.Register())
            .OnBeforeUninstallFastCallback(_ => CliPath.Register(remove: true))
            .Run();
        using var instance = SingleInstanceGuard.TryAcquire(
            Path.Combine(AppContext.BaseDirectory, "BotSpeaker.exe"));
        if (instance is null) return;

        var app = new App();
        app.InitializeComponent();
        app.Run();
    }

    public static string Version =>
        typeof(App).Assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
            .OfType<System.Reflection.AssemblyInformationalVersionAttribute>()
            .FirstOrDefault()?.InformationalVersion.Split('+')[0]
        ?? typeof(App).Assembly.GetName().Version?.ToString(3)
        ?? "0.0.0";

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Model = new AppModel();
        Orchestration = new OrchestrationController(Model);

        // Loopback control API for the botspeaker CLI; started before the
        // window so a CLI that launched us finds the discovery file quickly.
        var api = new ControlApi(Model, Orchestration, Version);
        _controlServer = new ControlServer(Dispatcher, Version, request => _exitRequested
            ? Task.FromResult(ControlServer.Response.Error(503, "Bot Speaker is quitting."))
            : api.HandleAsync(request));
        _controlServer.Start(Model.Settings.ControlPort);

        _mainWindow = new MainWindow(Model, Orchestration);
        if (e.Args.Contains("--background", StringComparer.OrdinalIgnoreCase))
        {
            // Launched by the CLI: run the window's Loaded work (voices,
            // session restore) but stay in the tray without stealing focus.
            _mainWindow.ShowActivated = false;
            _mainWindow.WindowState = WindowState.Minimized;
            _mainWindow.Show();
            _mainWindow.Hide();
            _mainWindow.WindowState = WindowState.Normal;
        }
        else
        {
            _mainWindow.Show();
        }

        SetUpTrayIcon();
        _updater = new WindowsUpdater();
        _updater.Changed += RefreshUpdateMenu;
        _updater.UpdateReady += version => _trayIcon?.ShowBalloonTip(
            5000, "BotSpeaker update ready", $"Version {version} is ready. Restart to update from the tray menu.", Forms.ToolTipIcon.Info);
        Model.PropertyChanged += (_, _) => RefreshUpdateMenu();
        Orchestration.PropertyChanged += (_, _) => RefreshUpdateMenu();
        RefreshUpdateMenu();
        _updater.Start();
        Model.Player.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName is nameof(AudioPlaybackController.IsPlaying) or nameof(AudioPlaybackController.IsBuffering))
                RefreshUpdateMenu();
            if (args.PropertyName == nameof(AudioPlaybackController.IsPlaying) && _playPauseItem is not null)
            {
                _playPauseItem.Text = Model.Player.IsPlaying ? "Pause" : "Play";
            }
        };
    }

    private void SetUpTrayIcon()
    {
        var menu = new Forms.ContextMenuStrip();
        var openItem = new Forms.ToolStripMenuItem("Open Bot Speaker");
        openItem.Click += (_, _) => ShowMainWindow();
        _playPauseItem = new Forms.ToolStripMenuItem("Play");
        _playPauseItem.Click += async (_, _) => await Model.PrimaryActionAsync();
        var stopItem = new Forms.ToolStripMenuItem("Stop");
        stopItem.Click += (_, _) => Model.StopPlayback();
        var exitItem = new Forms.ToolStripMenuItem("Quit");
        exitItem.Click += async (_, _) => await ExitApplicationAsync();
        _checkUpdateItem = new Forms.ToolStripMenuItem("Check for Updates…");
        _checkUpdateItem.Click += async (_, _) =>
        {
            if (_updater is null) return;
            var message = await _updater.CheckAsync(manual: true);
            if (message is not null)
                MessageBox.Show(message, "BotSpeaker Updates", MessageBoxButton.OK, MessageBoxImage.Information);
        };
        _restartUpdateItem = new Forms.ToolStripMenuItem("Restart to update") { Visible = false };
        _restartUpdateItem.Click += async (_, _) => await RestartToUpdateAsync();
        menu.Opening += (_, _) => RefreshUpdateMenu();
        menu.Items.AddRange([openItem, _playPauseItem, stopItem, new Forms.ToolStripSeparator(),
            _checkUpdateItem, _restartUpdateItem, new Forms.ToolStripSeparator(), exitItem]);

        using (var iconStream = typeof(App).Assembly.GetManifestResourceStream("BotSpeaker.Assets.BotSpeaker.ico"))
        {
            _appIcon = iconStream is not null ? new Drawing.Icon(iconStream) : Drawing.SystemIcons.Application;
        }
        _trayIcon = new Forms.NotifyIcon
        {
            Icon = _appIcon,
            Text = "Bot Speaker",
            Visible = true,
            ContextMenuStrip = menu,
        };
        _trayIcon.DoubleClick += (_, _) => ShowMainWindow();
    }

    public void ShowMainWindow()
    {
        if (_mainWindow is null) return;
        _mainWindow.Show();
        if (_mainWindow.WindowState == WindowState.Minimized)
        {
            _mainWindow.WindowState = WindowState.Normal;
        }
        _mainWindow.Activate();
    }

    private bool CanRestartForUpdate => !Model.IsGenerating && !Model.Player.IsPlaying
        && !Model.Player.IsBuffering && !Orchestration.IsActive && !Orchestration.IsBusy
        && !Model.Recall.HasPendingJobs && _mainWindow?.HasRecallMeetingWork != true && !_exitRequested;

    private void RefreshUpdateMenu()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(RefreshUpdateMenu);
            return;
        }
        if (_updater is null || _checkUpdateItem is null || _restartUpdateItem is null) return;
        _checkUpdateItem.Enabled = !_updater.IsBusy;
        _checkUpdateItem.Text = _updater.IsBusy ? "Checking / downloading update…" : "Check for Updates…";
        _restartUpdateItem.Visible = _updater.PendingUpdate is not null;
        _restartUpdateItem.Enabled = !_updater.IsBusy && CanRestartForUpdate;
        _restartUpdateItem.Text = CanRestartForUpdate ? "Restart to update" : "Restart to update (end playback / leave meeting first)";
    }

    private async Task RestartToUpdateAsync()
    {
        // Recheck at click time: meeting/playback state may have changed since opening the menu.
        if (_updater is null || _updater.IsBusy || _updater.PendingUpdate is null || !CanRestartForUpdate) return;
        try
        {
            // Velopack may terminate other processes using its install folder.
            // Refuse a restart while another app instance could be in a meeting.
            var instances = System.Diagnostics.Process.GetProcessesByName("BotSpeaker");
            try
            {
                if (instances.Any(process => process.Id != Environment.ProcessId))
                {
                    MessageBox.Show("Close the other BotSpeaker instances before installing the update.",
                        "BotSpeaker Updates", MessageBoxButton.OK, MessageBoxImage.Information);
                    return;
                }
            }
            finally
            {
                foreach (var process in instances) process.Dispose();
            }
            _updater.ApplyAndRestart();
            await ExitApplicationAsync();
        }
        catch (Exception error)
        {
            MessageBox.Show($"Could not install the update. Try again later.\n\n{error.Message}",
                "BotSpeaker Updates", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _updater?.Dispose();
        _controlServer?.Stop();
        base.OnExit(e);
    }

    public async Task ExitApplicationAsync()
    {
        if (_exitRequested || IsShuttingDown) return;
        _exitRequested = true;
        var windows = Windows.Cast<Window>().ToArray();
        try
        {
            if (Model.IsGenerating || Model.Player.IsPlaying || Model.Player.IsBuffering
                || Orchestration.IsActive || Orchestration.IsBusy
                || Model.Recall.HasPendingJobs || _mainWindow?.HasRecallMeetingWork == true
                || Orchestration.SpeechRequests.Any(request => !request.Status.IsTerminal()))
            {
                ShowMainWindow();
                var detail = Orchestration.IsHost
                    ? "Quitting will stop playback, end the hosted meeting, and disconnect its participants."
                    : Orchestration.IsActive
                        ? "Quitting will stop playback and leave the remote meeting. The host will be notified."
                        : "Quitting will stop playback, cancel pending speech, and remove orchestration speaker bots.";
                if (MessageBox.Show(_mainWindow!, detail + "\n\nQuit Bot Speaker?", "Quit Bot Speaker?",
                    MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) != MessageBoxResult.Yes) return;
            }
            foreach (var window in windows) window.IsEnabled = false;
            if (_trayIcon?.ContextMenuStrip is { } menu) menu.Enabled = false;
            if (_mainWindow is not null) _mainWindow.Title = "Bot Speaker — Finishing session and quitting…";
            await Orchestration.PrepareForExitAsync();
            if (_mainWindow is not null) await _mainWindow.PrepareRecallMeetingsForExitAsync();
            await Model.Recall.CancelPendingJobsAsync();
            Model.StopPlayback();
            IsShuttingDown = true;
            FinishShutdown();
        }
        catch (Exception error)
        {
            ShowMainWindow();
            MessageBox.Show(_mainWindow!, "Bot Speaker could not finish closing the session. The app will stay open so you can retry.\n\n" + error.Message,
                "Couldn’t quit", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            if (!IsShuttingDown)
            {
                foreach (var window in windows) window.IsEnabled = true;
                if (_trayIcon?.ContextMenuStrip is { } menu) menu.Enabled = true;
                if (_mainWindow is not null) _mainWindow.Title = "Bot Speaker";
                _exitRequested = false;
            }
        }
    }

    private void FinishShutdown()
    {
        _controlServer?.Stop();
        _controlServer = null;
        Model.Player.Reset();
        if (_trayIcon is not null)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _trayIcon = null;
        }
        _appIcon?.Dispose();
        _appIcon = null;
        Shutdown();
    }
}
