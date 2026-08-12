using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace BotSpeaker;

/// <summary>
/// Stores the ElevenLabs API key encrypted with DPAPI (current user scope) — the
/// Windows counterpart of the macOS Keychain storage.
/// </summary>
public sealed class CredentialStore
{
    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "BotSpeaker", "credentials.bin");

    public void Save(string value)
    {
        var directory = Path.GetDirectoryName(FilePath)!;
        Directory.CreateDirectory(directory);
        var encrypted = ProtectedData.Protect(
            Encoding.UTF8.GetBytes(value), optionalEntropy: null, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(FilePath, encrypted);
    }

    public string? Read()
    {
        if (!File.Exists(FilePath)) return null;
        try
        {
            var decrypted = ProtectedData.Unprotect(
                File.ReadAllBytes(FilePath), optionalEntropy: null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(decrypted);
        }
        catch (CryptographicException)
        {
            return null;
        }
    }

    public void Delete()
    {
        if (File.Exists(FilePath)) File.Delete(FilePath);
    }
}
