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
        _controlServer = new ControlServer(Dispatcher, Version, api.HandleAsync);
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
        Model.Player.PropertyChanged += (_, args) =>
        {
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
        exitItem.Click += (_, _) => ExitApplication();
        menu.Items.AddRange([openItem, _playPauseItem, stopItem, new Forms.ToolStripSeparator(), exitItem]);

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

    protected override void OnExit(ExitEventArgs e)
    {
        _controlServer?.Stop();
        base.OnExit(e);
    }

    public void ExitApplication()
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
