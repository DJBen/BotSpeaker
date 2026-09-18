using System.Text;
using BotSpeaker.Cli;
using System.Text.Json.Nodes;

static partial class Cli
{
    private static string RecallHelp => $"""
        USAGE: {Name} recall <action> [options]
          configure [--region REGION] [--key-stdin]  env key or hidden prompt
          list                                      list bots and status
          status                                    configuration and local jobs
          add MEETING_URL [--name NAME]              join a meeting
          remove BOT_ID                             leave and cancel pending jobs
          speak BOT_ID TEXT [--voice ID] [--file PATH]
            [--at now|+SECONDS|ISO8601] [--loop | --repeat N] [--interval SECONDS]
          cancel JOB_ID                             stop future dispatches
        Keep the app running and awake. Times specify dispatch, not audible playback.
        Cancel cannot retract audio already sent. Output is JSON (also accepts --json).
        """;

    private static async Task<int> RecallAsync(Args args)
    {
        var action = args.Positional.FirstOrDefault() ?? "status";
        if (!new[] { "configure", "status", "list", "add", "remove", "speak", "cancel" }.Contains(action)) throw new UsageException("Unknown recall action. Use recall --help.");
        var body = new JsonObject();
        if (action == "configure")
        {
            var key = Environment.GetEnvironmentVariable("RECALL_API_KEY") ?? Environment.GetEnvironmentVariable("RECALL_API_KEY", EnvironmentVariableTarget.User)
                ?? Environment.GetEnvironmentVariable("RECALL_AI_API_KEY", EnvironmentVariableTarget.User);
            if (args.Flag("key-stdin")) key = ReadStdin().Trim();
            if (string.IsNullOrWhiteSpace(key) && !Console.IsInputRedirected)
            {
                Console.Error.Write("Recall API key (blank keeps saved key): ");
                var secret = new StringBuilder();
                while (true) { var k = Console.ReadKey(true); if (k.Key == ConsoleKey.Enter) break; if (k.Key == ConsoleKey.Backspace) { if (secret.Length > 0) secret.Length--; } else if (!char.IsControl(k.KeyChar)) secret.Append(k.KeyChar); }
                Console.Error.WriteLine(); key = secret.ToString();
            }
            if (!string.IsNullOrWhiteSpace(key)) body["apiKey"] = key;
            if (args.Option("region") is string region) body["region"] = region;
        }
        if (action == "add") { body["meetingUrl"] = args.Positional.ElementAtOrDefault(1); body["name"] = args.Option("name") ?? "BotSpeaker"; }
        if (action is "remove" or "speak") body["botId"] = args.Positional.ElementAtOrDefault(1);
        if (action == "cancel") body["id"] = args.Positional.ElementAtOrDefault(1);
        if (action == "speak")
        {
            var (loop, repeat) = args.Cycles();
            body["text"] = args.Option("file", "f") is string file ? (file == "-" ? ReadStdin() : File.ReadAllText(file)) : string.Join(" ", args.Positional.Skip(2));
            body["at"] = args.Option("at") ?? "now"; body["loop"] = loop;
            if (repeat != null) body["repeat"] = repeat;
            if (args.Option("voice") is string voice) body["voice"] = voice;
            if (args.Option("interval") is string interval) { if (!double.TryParse(interval, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var seconds)) throw new UsageException("--interval must be seconds."); body["interval"] = seconds; }
        }
        var client = await ControlClient.LocateAsync();
        Output.Json(await client.PostAsync("/v1/recall/" + action, body));
        return 0;
    }
}
