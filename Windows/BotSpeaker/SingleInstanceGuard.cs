using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace BotSpeaker;

/// <summary>Holds an atomic, process-lifetime lock for an executable path.</summary>
internal sealed class SingleInstanceGuard : IDisposable
{
    private readonly Mutex _mutex;
    private bool _disposed;

    private SingleInstanceGuard(Mutex mutex) => _mutex = mutex;

    // Acquire and dispose on the main thread: Windows mutex ownership is thread-affine.
    public static SingleInstanceGuard? TryAcquire(string executablePath)
    {
        var path = Path.GetFullPath(executablePath).ToUpperInvariant();
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(path)));
        var mutex = new Mutex(false, @"Global\BotSpeaker.Path." + hash);
        try
        {
            try
            {
                if (mutex.WaitOne(0)) return new SingleInstanceGuard(mutex);
            }
            catch (AbandonedMutexException)
            {
                // The previous process crashed; WaitOne has granted us ownership.
                return new SingleInstanceGuard(mutex);
            }
            mutex.Dispose();
            return null;
        }
        catch
        {
            mutex.Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _mutex.ReleaseMutex();
        _mutex.Dispose();
        _disposed = true;
    }
}
