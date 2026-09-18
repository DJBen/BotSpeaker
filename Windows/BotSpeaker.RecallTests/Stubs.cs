// Deterministic substitutes for OS credentials, paid synthesis, and MP3 duration.
namespace BotSpeaker
{
    public sealed class AppException(string message) : Exception(message);
    public sealed class AppModel { public string VoiceId => "voice"; public string ModelId => "model"; }
    public sealed class CredentialStore(string filename = "credentials.bin") { public string Read() => "test-secret"; public void Save(string key) { } }
    public sealed record SpeechClip(string AudioPath);
    public sealed class ElevenLabsClient
    {
        public async Task<SpeechClip> SynthesizeAsync(string text, string voice, string model, string key, string space, bool bypass, CancellationToken token)
        {
            if (text.StartsWith("slow")) await Task.Delay(300, token);
            var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "botspeaker-recall-test-" + Guid.NewGuid());
            await System.IO.File.WriteAllTextAsync(path, text, token);
            return new(path);
        }
    }
}
namespace NAudio.Wave
{
    public sealed class Mp3FileReader(string path) : IDisposable { public TimeSpan TotalTime => TimeSpan.Zero; public void Dispose() { System.IO.File.Delete(path); } }
}
