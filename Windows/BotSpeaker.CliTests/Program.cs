using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Windows.Threading;
using BotSpeaker;
using BotSpeaker.Cli;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "hold")
        {
            Console.WriteLine("ready");
            Console.ReadLine();
            return 0;
        }
        var sandbox = Path.Combine(Path.GetTempPath(), "botspeaker-cli-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(sandbox);
        try
        {
            Require(CliPath.Rewrite(null, @"C:\new") == @"C:\new", "empty user PATH");
            Require(CliPath.Rewrite(@"C:\old;C:\NEW\;C:\tools", @"C:\new") == @"C:\new;C:\old;C:\tools", "new CLI wins and duplicate is removed");
            Require(CliPath.Rewrite(@"C:\new;C:\tools", @"C:\new", true) == @"C:\tools", "uninstall preserves other PATH entries");
            byte[] data = [1, 2, 3];
            CliUpgrade.VerifyChecksum(data, Convert.ToHexString(SHA256.HashData(data)) + "  file.zip\n");
            Throws<InvalidDataException>(() => CliUpgrade.VerifyChecksum(data, new string('0', 64)), "corrupt download rejected");
            Throws<InvalidDataException>(() => CliUpgrade.VerifyChecksum(data, ""), "missing digest rejected");

            var target = Path.Combine(sandbox, "target.exe");
            var staged = Path.Combine(sandbox, "staged.exe");
            File.WriteAllText(target, "old");
            File.WriteAllText(staged, "new");
            using (var worker = CliUpgrade.StartReplacement(staged, target, int.MaxValue))
                Require(worker.WaitForExit(10000) && worker.ExitCode == 0, "replacement worker succeeds");
            Require(File.ReadAllText(target) == "new", "replacement installed");
            File.WriteAllText(staged, "blocked");
            using (var locked = File.Open(staged, FileMode.Open, FileAccess.Read, FileShare.None))
            using (var worker = CliUpgrade.StartReplacement(staged, target, int.MaxValue))
                Require(worker.WaitForExit(10000) && worker.ExitCode == 1, "failed replacement reports failure");
            Require(File.ReadAllText(target) == "new", "failed replacement restores executable");
            File.Delete(staged);

            // Exercise Windows image locking using a real running apphost.
            foreach (var file in Directory.GetFiles(AppContext.BaseDirectory))
                File.Copy(file, Path.Combine(sandbox, Path.GetFileName(file)), true);
            var childPath = Path.Combine(sandbox, Path.GetFileName(Environment.ProcessPath!));
            using (var child = Process.Start(new ProcessStartInfo(childPath, "hold")
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true })!)
            {
                try
                {
                    Require(child.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)).GetAwaiter().GetResult() == "ready", "test image is running");
                    File.Copy(Environment.ProcessPath!, staged);
                    using var worker = CliUpgrade.StartReplacement(staged, childPath, child.Id);
                    Require(!worker.WaitForExit(1000) && !File.Exists(childPath + ".previous"), "worker waits for CLI exit");
                    child.StandardInput.WriteLine();
                    Require(child.WaitForExit(5000) && worker.WaitForExit(10000) && worker.ExitCode == 0,
                        "worker installs after CLI exit");
                }
                finally { if (!child.HasExited) child.Kill(); }
            }

            var discovery = Path.Combine(sandbox, "control.json");
            var server = new ControlServer(Dispatcher.CurrentDispatcher, "1.2.3",
                _ => Task.FromResult(ControlServer.Response.Ok(new JsonObject { ["ok"] = true })), discovery);
            try
            {
                server.Start(0);
                var original = File.ReadAllText(discovery);
                File.Delete(discovery);
                var frame = new DispatcherFrame();
                var timeout = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
                timeout.Tick += (_, _) => { timeout.Stop(); frame.Continue = false; };
                timeout.Start();
                Dispatcher.PushFrame(frame);
                Require(File.ReadAllText(discovery) == original, "missing discovery restored with same token and port");
                using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
                Require(http.GetAsync($"http://127.0.0.1:{server.Port}/health").GetAwaiter().GetResult().IsSuccessStatusCode,
                    "server remains reachable after discovery repair");
            }
            finally { server.Stop(); }
            Require(!File.Exists(discovery), "shutdown removes discovery");
            Console.WriteLine("All CLI installation, replacement, and discovery checks passed.");
            return 0;
        }
        finally { Directory.Delete(sandbox, recursive: true); }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
        Console.WriteLine("PASS: " + message);
    }
    private static void Throws<T>(Action action, string message) where T : Exception
    {
        try { action(); } catch (T) { Console.WriteLine("PASS: " + message); return; }
        throw new Exception(message);
    }
}
