using System.Diagnostics;
using BotSpeaker;

// Child processes exercise real cross-process exclusion without starting the UI.
if (args.Length > 0)
{
    using var guard = SingleInstanceGuard.TryAcquire(args[1]);
    if (guard is null) return 2;
    if (args[0] == "hold")
    {
        Console.WriteLine("ready");
        Console.Out.Flush();
        Console.ReadLine();
    }
    return 0;
}

var path = Path.Combine(Path.GetTempPath(), "botspeaker-instance-" + Guid.NewGuid(), "BotSpeaker.exe");
using (var owner = SingleInstanceGuard.TryAcquire(path))
{
    Require(owner is not null, "first launch acquires guard");
    Require(Probe(path) == 2, "duplicate launch is rejected");
    Require(Probe(path.ToUpperInvariant()) == 2, "path casing shares guard");
    Require(Probe(Path.Combine(Path.GetDirectoryName(path)!, ".", "BotSpeaker.exe")) == 2,
        "equivalent full paths share guard");
    Require(Probe(path + ".other") == 0, "different executable paths can coexist");
}
Require(Probe(path) == 0, "normal exit releases guard");

using (var child = Start("hold", path))
{
    try
    {
        Require(child.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)).GetAwaiter().GetResult() == "ready",
            "child acquires guard");
        Require(Probe(path) == 2, "child ownership excludes other processes");
        child.Kill();
        Require(child.WaitForExit(10000), "crashed child exits");
        Require(Probe(path) == 0, "crash permits relaunch");
    }
    finally
    {
        if (!child.HasExited) child.Kill();
    }
}
Console.WriteLine("All single-instance checks passed.");
return 0;

static Process Start(string mode, string path)
{
    var start = new ProcessStartInfo(Environment.ProcessPath!)
    {
        RedirectStandardInput = true,
        RedirectStandardOutput = true,
        UseShellExecute = false,
        CreateNoWindow = true,
    };
    start.ArgumentList.Add(mode);
    start.ArgumentList.Add(path);
    return Process.Start(start)!;
}

static int Probe(string path)
{
    using var child = Start("probe", path);
    if (!child.WaitForExit(10000))
    {
        child.Kill();
        throw new Exception("Guard probe timed out.");
    }
    return child.ExitCode;
}

static void Require(bool condition, string message)
{
    if (!condition) throw new Exception("FAIL: " + message);
    Console.WriteLine("PASS: " + message);
}
