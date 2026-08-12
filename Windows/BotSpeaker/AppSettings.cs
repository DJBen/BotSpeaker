using System.IO;
using System.Text.Json;

namespace BotSpeaker;

/// <summary>JSON-file settings — the Windows counterpart of the macOS UserDefaults keys.</summary>
public sealed class AppSettings
{
    public string VoiceId { get; set; } = "JBFqnCBsd6RMkjVDRZzb";
    public string ModelId { get; set; } = "eleven_flash_v2_5";
    public string OutputDeviceId { get; set; } = "";
    public bool LoopEnabled { get; set; }
    public double OutputVolume { get; set; } = 1;
    public bool InterruptionEnabled { get; set; }
    public string InterruptionInputId { get; set; } = "";
    public string SelectedScriptId { get; set; } = "";
    public List<CustomSpeechScript> CustomScripts { get; set; } = [];

    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "BotSpeaker", "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new AppSettings();
            }
        }
        catch (JsonException)
        {
        }
        return new AppSettings();
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this, JsonOptions));
    }
}
