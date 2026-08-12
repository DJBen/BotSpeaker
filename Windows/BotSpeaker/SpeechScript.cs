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
}

public sealed record ExampleExcerpt(string Id, string Role, string Meeting, string Text)
{
    public SpeechScript SpeechScript => new($"example:{Id}", Role, Meeting, Text, CustomId: null);

    public static readonly ExampleExcerpt ProductLaunch = Load(
        "product-launch", "Senior Product Manager", "Launch readiness review");
    public static readonly ExampleExcerpt EnterpriseDiscovery = Load(
        "enterprise-discovery", "Enterprise Account Executive", "Executive discovery call");
    public static readonly ExampleExcerpt IncidentReview = Load(
        "incident-review", "Engineering Manager", "Production incident review");

    public static readonly IReadOnlyList<ExampleExcerpt> All =
        [ProductLaunch, EnterpriseDiscovery, IncidentReview];

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
