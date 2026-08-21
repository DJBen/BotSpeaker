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
    private OrchestrationWindow? _orchestrationWindow;
    private Forms.NotifyIcon? _trayIcon;
    private Forms.ToolStripMenuItem? _playPauseItem;
    private Drawing.Icon? _appIcon;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Model = new AppModel();
        Orchestration = new OrchestrationController(Model);

        _mainWindow = new MainWindow(Model);
        _mainWindow.Show();

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

    public void ShowOrchestrationWindow()
    {
        if (_orchestrationWindow is null || !_orchestrationWindow.IsLoaded)
        {
            _orchestrationWindow = new OrchestrationWindow(Model, Orchestration);
        }
        _orchestrationWindow.Show();
        if (_orchestrationWindow.WindowState == WindowState.Minimized)
        {
            _orchestrationWindow.WindowState = WindowState.Normal;
        }
        _orchestrationWindow.Activate();
    }

    public void ExitApplication()
    {
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
