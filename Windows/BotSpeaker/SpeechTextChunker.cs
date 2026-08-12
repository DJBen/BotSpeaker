namespace BotSpeaker;

/// <summary>A contiguous slice of the source text, in UTF-16 code units.</summary>
public readonly record struct TextSpan(int Location, int Length)
{
    public int End => Location + Length;
}

public sealed record SpeechChunkPlan(string Text, TextSpan SourceRange, string? PreviousText, string? NextText);

/// <summary>
/// Splits a long script into ElevenLabs-sized requests, preferring sentence breaks,
/// then word breaks, between the minimum and maximum chunk sizes. Mirrors the macOS
/// SpeechTextChunker so the two apps produce identical cache keys for identical text.
/// </summary>
public static class SpeechTextChunker
{
    private const int TargetCharacterCount = 420;
    private const int MinimumCharacterCount = 240;
    private const int MaximumCharacterCount = 650;
    private const int ContextCharacterCount = 300;

    public static List<SpeechChunkPlan> Chunks(string source)
    {
        var plans = new List<SpeechChunkPlan>();
        int contentStart = 0;
        while (contentStart < source.Length && char.IsWhiteSpace(source[contentStart])) contentStart++;
        if (contentStart >= source.Length) return plans;

        int contentEnd = source.Length;
        while (contentEnd > contentStart && char.IsWhiteSpace(source[contentEnd - 1])) contentEnd--;

        var ranges = new List<(int Start, int End)>();
        int cursor = contentStart;

        while (cursor < contentEnd)
        {
            int remaining = contentEnd - cursor;
            if (remaining <= MaximumCharacterCount)
            {
                ranges.Add((cursor, contentEnd));
                break;
            }

            int maximumEnd = Math.Min(cursor + MaximumCharacterCount, contentEnd);
            int minimumEnd = Math.Min(cursor + MinimumCharacterCount, maximumEnd);
            int targetEnd = Math.Min(cursor + TargetCharacterCount, maximumEnd);

            var sentenceBreaks = new List<int>();
            var wordBreaks = new List<int>();
            for (int index = cursor; index < maximumEnd; index++)
            {
                char character = source[index];
                if (char.IsWhiteSpace(character)) wordBreaks.Add(index + 1);
                if (character is '.' or '!' or '?' or '\n') sentenceBreaks.Add(index + 1);
            }

            int? end = BestBreak(sentenceBreaks, minimumEnd, targetEnd, maximumEnd)
                ?? BestBreak(wordBreaks, minimumEnd, targetEnd, maximumEnd);
            int chunkEnd = end ?? maximumEnd;
            ranges.Add((cursor, chunkEnd));

            cursor = chunkEnd;
            while (cursor < contentEnd && char.IsWhiteSpace(source[cursor])) cursor++;
        }

        foreach (var (start, end) in ranges)
        {
            var text = source[start..end].Trim();
            if (text.Length == 0) continue;
            plans.Add(new SpeechChunkPlan(
                text,
                new TextSpan(start, end - start),
                ContextBefore(start, source),
                ContextAfter(end, source)));
        }
        return plans;
    }

    private static int? BestBreak(List<int> candidates, int minimum, int target, int maximum)
    {
        var valid = candidates.Where(c => c >= minimum && c <= maximum).ToList();
        if (valid.Count == 0) return null;
        foreach (var candidate in valid)
        {
            if (candidate >= target) return candidate;
        }
        return valid[^1];
    }

    private static string? ContextBefore(int index, string source)
    {
        if (index <= 0) return null;
        int start = Math.Max(index - ContextCharacterCount, 0);
        var value = source[start..index].Trim();
        return value.Length == 0 ? null : value;
    }

    private static string? ContextAfter(int index, string source)
    {
        if (index >= source.Length) return null;
        int end = Math.Min(index + ContextCharacterCount, source.Length);
        var value = source[index..end].Trim();
        return value.Length == 0 ? null : value;
    }
}
