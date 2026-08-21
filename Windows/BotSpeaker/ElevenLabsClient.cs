using System.IO;
using System.Net.Http;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace BotSpeaker;

public sealed class AppException(string message, int? statusCode = null) : Exception(message)
{
    public int? StatusCode { get; } = statusCode;
}

public sealed record SpeechClip(string AudioPath, SpeechTiming Timing);

public sealed class ElevenLabsClient
{
    public const double DefaultSpeechSpeed = 1.1;
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(180) };
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    public async Task ValidateAsync(string apiKey, CancellationToken cancellation = default)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            "https://api.elevenlabs.io/v2/voices?page_size=1&include_total_count=false");
        request.Headers.Add("xi-api-key", apiKey);
        using var response = await Http.SendAsync(request, cancellation);
        await ValidateAsync(response, cancellation);
    }

    public async Task<List<ElevenLabsVoice>> ListVoicesAsync(string apiKey, CancellationToken cancellation = default)
    {
        var voices = new List<ElevenLabsVoice>();
        string? nextPageToken = null;

        do
        {
            var url = "https://api.elevenlabs.io/v2/voices?page_size=100&sort=name&sort_direction=asc&include_total_count=false";
            if (nextPageToken is not null)
            {
                url += "&next_page_token=" + Uri.EscapeDataString(nextPageToken);
            }
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.Add("xi-api-key", apiKey);
            using var response = await Http.SendAsync(request, cancellation);
            await ValidateAsync(response, cancellation);
            var page = await response.Content.ReadFromJsonAsync<VoicePage>(JsonOptions, cancellation)
                ?? throw new AppException("ElevenLabs returned an invalid voice list.");
            voices.AddRange(page.Voices);
            nextPageToken = page.HasMore ? page.NextPageToken : null;
        } while (nextPageToken is not null);

        return voices
            .GroupBy(v => v.Id)
            .Select(g => g.Last())
            .OrderBy(v => v.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }

    public async Task<SpeechClip> SynthesizeAsync(
        string text,
        string voiceId,
        string modelId,
        string apiKey,
        string? previousText,
        string? nextText,
        string cacheNamespace,
        bool bypassCache,
        CancellationToken cancellation = default)
    {
        var (audioPath, timingPath) = CachePaths(text, voiceId, modelId, previousText, nextText, cacheNamespace);
        if (!bypassCache && File.Exists(audioPath) && File.Exists(timingPath))
        {
            try
            {
                var cachedTiming = JsonSerializer.Deserialize<SpeechTiming>(
                    await File.ReadAllTextAsync(timingPath, cancellation), JsonOptions);
                if (cachedTiming is not null) return new SpeechClip(audioPath, cachedTiming);
            }
            catch (JsonException)
            {
                // Corrupt cache entry — fall through and regenerate.
            }
        }

        var url = $"https://api.elevenlabs.io/v1/text-to-speech/{Uri.EscapeDataString(voiceId)}/with-timestamps?output_format=mp3_44100_128";
        using var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Headers.Add("xi-api-key", apiKey);
        request.Headers.Add("Accept", "audio/mpeg");
        request.Content = new StringContent(
            JsonSerializer.Serialize(new SpeechRequest(
                text,
                modelId,
                previousText,
                nextText,
                new VoiceSettings(DefaultSpeechSpeed))),
            Encoding.UTF8,
            "application/json");

        using var response = await Http.SendAsync(request, cancellation);
        await ValidateAsync(response, cancellation);
        var body = await response.Content.ReadFromJsonAsync<TimedSpeechResponse>(JsonOptions, cancellation)
            ?? throw new AppException("ElevenLabs returned an invalid response.");

        byte[] audioData;
        try
        {
            audioData = Convert.FromBase64String(body.AudioBase64 ?? "");
        }
        catch (FormatException)
        {
            throw new AppException("ElevenLabs returned invalid audio data.");
        }
        if (audioData.Length == 0) throw new AppException("ElevenLabs returned invalid audio data.");

        var timing = SpeechTiming.FromAlignment(body.Alignment ?? body.NormalizedAlignment, text);
        await File.WriteAllBytesAsync(audioPath, audioData, cancellation);
        await File.WriteAllTextAsync(timingPath, JsonSerializer.Serialize(timing), cancellation);
        return new SpeechClip(audioPath, timing);
    }

    private static (string Audio, string Timing) CachePaths(
        string text, string voiceId, string modelId, string? previousText, string? nextText, string cacheNamespace)
    {
        var baseDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "BotSpeaker", "Audio", SafeCacheComponent(cacheNamespace));
        Directory.CreateDirectory(baseDirectory);
        var digest = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(
            $"{voiceId}|{modelId}|speed={DefaultSpeechSpeed}|{previousText ?? ""}|{text}|{nextText ?? ""}")));
        var stem = Path.Combine(baseDirectory, digest);
        return (stem + ".mp3", stem + ".timing.json");
    }

    private static string SafeCacheComponent(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var character in value)
        {
            builder.Append(char.IsLetterOrDigit(character) || character is '-' or '_' ? character : '-');
        }
        var result = builder.ToString().Replace("--", "-");
        if (result.Length == 0) return "unnamed-script";
        return result.Length > 100 ? result[..100] : result;
    }

    private static async Task ValidateAsync(HttpResponseMessage response, CancellationToken cancellation)
    {
        if (response.IsSuccessStatusCode) return;
        string message = response.ReasonPhrase ?? $"HTTP {(int)response.StatusCode}";
        try
        {
            var envelope = await response.Content.ReadFromJsonAsync<ApiErrorEnvelope>(JsonOptions, cancellation);
            if (!string.IsNullOrEmpty(envelope?.Detail?.Message)) message = envelope.Detail.Message;
        }
        catch (JsonException)
        {
        }
        throw new AppException($"ElevenLabs: {message}");
    }

    private sealed record SpeechRequest(
        [property: JsonPropertyName("text")] string Text,
        [property: JsonPropertyName("model_id")] string ModelId,
        [property: JsonPropertyName("previous_text")] string? PreviousText,
        [property: JsonPropertyName("next_text")] string? NextText,
        [property: JsonPropertyName("voice_settings")] VoiceSettings VoiceSettings);

    private sealed record VoiceSettings(
        [property: JsonPropertyName("speed")] double Speed);

    private sealed record TimedSpeechResponse(
        [property: JsonPropertyName("audio_base64")] string? AudioBase64,
        [property: JsonPropertyName("alignment")] SpeechAlignment? Alignment,
        [property: JsonPropertyName("normalized_alignment")] SpeechAlignment? NormalizedAlignment);

    private sealed record VoicePage(
        [property: JsonPropertyName("voices")] List<ElevenLabsVoice> Voices,
        [property: JsonPropertyName("has_more")] bool HasMore,
        [property: JsonPropertyName("next_page_token")] string? NextPageToken);

    private sealed record ApiErrorEnvelope([property: JsonPropertyName("detail")] ApiErrorDetail? Detail);
    private sealed record ApiErrorDetail([property: JsonPropertyName("message")] string? Message);
}

public sealed record SpeechAlignment(
    [property: JsonPropertyName("characters")] List<string> Characters,
    [property: JsonPropertyName("character_start_times_seconds")] List<double> CharacterStartTimes,
    [property: JsonPropertyName("character_end_times_seconds")] List<double> CharacterEndTimes);

public sealed record ElevenLabsVoice(
    [property: JsonPropertyName("voice_id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("category")] string? Category,
    [property: JsonPropertyName("description")] string? Description,
    [property: JsonPropertyName("labels")] Dictionary<string, string>? Labels)
{
    public string Detail => string.Join(" · ",
        new[] { Labels?.GetValueOrDefault("accent"), Labels?.GetValueOrDefault("gender"), Labels?.GetValueOrDefault("use_case") }
            .Select(v => v?.Trim())
            .Where(v => !string.IsNullOrEmpty(v)));

    public string DisplayName => Detail.Length == 0 ? Name : $"{Name} — {Detail}";
}

public sealed record TimedTextSpan(double StartTime, double EndTime, int Location, int Length);

public sealed class SpeechTiming
{
    public List<double> WordBoundaries { get; init; } = [];
    public List<double> SentenceBoundaries { get; init; } = [];
    public List<double> CharacterEndTimes { get; init; } = [];
    public List<int> CharacterUtf16Offsets { get; init; } = [];
    public List<TimedTextSpan> SentenceSpans { get; init; } = [];

    private static readonly char[] SentenceTerminators = ['.', '!', '?', ';', ':', '\n'];

    public static SpeechTiming FromAlignment(SpeechAlignment? alignment, string sourceText)
    {
        if (alignment is null) return new SpeechTiming();

        int count = Math.Min(alignment.Characters.Count, alignment.CharacterEndTimes.Count);
        var words = new List<double>();
        var sentences = new List<double>();
        var characterTimes = new List<double>();
        var characterOffsets = new List<int>();
        var sentenceSpans = new List<TimedTextSpan>();
        int utf16Offset = 0;
        int sentenceStartOffset = 0;
        double sentenceStartTime = 0;
        int sourceLength = sourceText.Length;

        for (int index = 0; index < count; index++)
        {
            var character = alignment.Characters[index];
            var time = alignment.CharacterEndTimes[index];
            utf16Offset = Math.Min(utf16Offset + character.Length, sourceLength);
            characterTimes.Add(time);
            characterOffsets.Add(utf16Offset);
            if (character.IndexOfAny(SentenceTerminators) >= 0)
            {
                sentences.Add(time);
                words.Add(time);
                if (utf16Offset > sentenceStartOffset)
                {
                    sentenceSpans.Add(new TimedTextSpan(
                        sentenceStartTime, time, sentenceStartOffset, utf16Offset - sentenceStartOffset));
                }
                sentenceStartOffset = utf16Offset;
                sentenceStartTime = time;
            }
            else if (character.Any(char.IsWhiteSpace) && index > 0)
            {
                words.Add(alignment.CharacterEndTimes[index - 1]);
            }
        }

        if (sentenceStartOffset < sourceLength)
        {
            var endTime = count > 0 ? alignment.CharacterEndTimes[count - 1] : sentenceStartTime;
            sentenceSpans.Add(new TimedTextSpan(
                sentenceStartTime, endTime, sentenceStartOffset, sourceLength - sentenceStartOffset));
        }

        return new SpeechTiming
        {
            WordBoundaries = words.Distinct().Order().ToList(),
            SentenceBoundaries = sentences.Distinct().Order().ToList(),
            CharacterEndTimes = characterTimes,
            CharacterUtf16Offsets = characterOffsets,
            SentenceSpans = sentenceSpans,
        };
    }

    /// <summary>UTF-16 offset of the last character whose end time is at or before <paramref name="time"/>.</summary>
    public int PlayedUtf16Offset(double time)
    {
        if (CharacterEndTimes.Count == 0) return 0;
        int lower = 0;
        int upper = CharacterEndTimes.Count;
        while (lower < upper)
        {
            int middle = (lower + upper) / 2;
            if (CharacterEndTimes[middle] <= time) lower = middle + 1;
            else upper = middle;
        }
        if (lower == 0 || lower - 1 >= CharacterUtf16Offsets.Count) return 0;
        return CharacterUtf16Offsets[lower - 1];
    }
}
