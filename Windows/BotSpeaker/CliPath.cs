using System.Diagnostics;
using System.Runtime.InteropServices;

namespace BotSpeaker;

internal static class CliPath
{
    // The managed current directory remains stable across Velopack updates.
    internal static string Rewrite(string? path, string directory, bool remove = false)
    {
        var entries = (path ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries)
            .Where(entry => !string.Equals(Environment.ExpandEnvironmentVariables(entry.Trim().Trim('"')).TrimEnd('\\', '/'),
                directory.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase));
        return string.Join(';', remove ? entries : new[] { directory }.Concat(entries));
    }

    internal static void Register(bool remove = false)
    {
        try
        {
            var directory = AppContext.BaseDirectory.TrimEnd('\\', '/');
            var previous = Environment.GetEnvironmentVariable("Path", EnvironmentVariableTarget.User);
            var updated = Rewrite(previous, directory, remove);
            if (previous == updated) return;
            Environment.SetEnvironmentVariable("Path", updated, EnvironmentVariableTarget.User);
            SendMessageTimeout(new IntPtr(0xffff), 0x001a, IntPtr.Zero, "Environment", 2, 1000, out _);
        }
        catch (Exception error) { Trace.TraceWarning("Could not register BotSpeaker CLI on PATH: {0}", error.Message); }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam,
        string lParam, uint flags, uint timeout, out IntPtr result);
}
