using System.IO;
using System.Reflection;

namespace BotSpeaker;

public sealed record SpeechScript(string Id, string Title, string Detail, string Text, Guid? CustomId)
{
    public bool IsCustom => CustomId is not null;
    public string CacheNamespace => Id;
    public int WordCount => Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
}

public sealed class CustomSpeechScript
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    public string Text { get; set; } = "";
    public string? Detail { get; set; }
}

public sealed record ExampleScenario(string Id, string Title, IReadOnlyList<ExampleExcerpt> Excerpts);

/// <summary>
/// A role-specific script from a coordinated meeting scenario. Built-in
/// scripts are templates: {{name}} is resolved once when a user creates a
/// named copy, so playback and caching never depend on mutable profile data.
/// Scripts are written for ElevenLabs v3: bracketed audio tags such as
/// [laughs] or [sighs] steer the expressive delivery.
/// </summary>
public sealed record ExampleExcerpt(string Id, string Role, string Meeting, string Text)
{
    public const string NamePlaceholder = "{{name}}";

    public SpeechScript SpeechScript => new($"example:{Id}", Role, Meeting, Text, CustomId: null);

    public static readonly ExampleExcerpt LaunchRetroProductManager = Load(
        "launch-retro-product-manager", "Product Manager", "Q3 launch retrospective");
    public static readonly ExampleExcerpt LaunchRetroEngineeringLead = Load(
        "launch-retro-engineering-lead", "Engineering Lead", "Q3 launch retrospective");
    public static readonly ExampleExcerpt LaunchRetroSupportLead = Load(
        "launch-retro-support-lead", "Customer Success Lead", "Q3 launch retrospective");

    public static readonly IReadOnlyList<ExampleScenario> Scenarios =
    [
        new("q3-launch-retrospective", "Script templates",
            [LaunchRetroProductManager, LaunchRetroEngineeringLead, LaunchRetroSupportLead]),
    ];

    public static readonly IReadOnlyList<ExampleExcerpt> All =
        Scenarios.SelectMany(s => s.Excerpts).ToList();

    private static ExampleExcerpt Load(string id, string role, string meeting)
    {
        var assembly = Assembly.GetExecutingAssembly();
        using var stream = assembly.GetManifestResourceStream($"BotSpeaker.Examples.{id}.txt")
            ?? throw new InvalidOperationException($"Missing embedded example {id}");
        using var reader = new StreamReader(stream);
        var text = reader.ReadToEnd().Replace("\r\n", "\n").TrimEnd('\n');
        return new ExampleExcerpt(id, role, meeting, text);
    }
}
