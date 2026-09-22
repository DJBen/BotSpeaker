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
          list --meeting URL_OR_ID                  filter bots to one meeting
          add ID --passcode CODE                    join Teams using ID and passcode
          add --file PATH|-                         read a full invitation
          remove-all --meeting URL_OR_ID            remove all bots in that meeting
          prepare BOT_ID TEXT [--voice ID] [--file PATH] [--wait]
          dispatch JOB_ID [--wait]                   play a prepared clip
          wait JOB_ID [--timeout SECONDS]            wait for dispatch completion
          meeting-create --file PLAN.json|-         plan turns using botId, voice, text
          meeting-start PLAN_ID [--wait]             prepare all turns, then play
          meeting-status PLAN_ID                    inspect progress
          meeting-skip PLAN_ID                       skip the current turn
          meeting-stop PLAN_ID                       stop and cancel pending turns
          meeting-wait PLAN_ID [--timeout SECONDS]   wait for the plan to finish
        speak, prepare, dispatch, and meeting-start accept --wait and --timeout.
        Plan IDs and job IDs last for this app process; stopping leaves bots joined.
        Keep the app running and awake. Times specify dispatch, not audible playback.
        Cancel cannot retract audio already sent. Output is JSON (also accepts --json).
        """;

    private static async Task<int> RecallAsync(Args args)
    {
        var action = args.Positional.FirstOrDefault() ?? "status";
        var body = new JsonObject();
        if (action == "configure")
        {
            if (args.Positional.Count != 1 || args.Options.Keys.Any(key => key is not ("json" or "region" or "key-stdin")))
                throw new UsageException("configure accepts --region, --key-stdin, and --json.");
            var key = Environment.GetEnvironmentVariable("RECALL_API_KEY") ?? Environment.GetEnvironmentVariable("RECALL_API_KEY", EnvironmentVariableTarget.User)
                ?? Environment.GetEnvironmentVariable("RECALL_AI_API_KEY") ?? Environment.GetEnvironmentVariable("RECALL_AI_API_KEY", EnvironmentVariableTarget.User);
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
        else
        {
            try { (action, body) = RecallCommands.Build(args.Positional, args.Options, file => file == "-" ? ReadStdin() : File.ReadAllText(file)); }
            catch (ArgumentException error) { throw new UsageException(error.Message); }
        }
        var timeout = args.Timeout;
        if (!double.IsFinite(timeout)) throw new UsageException("--timeout must be finite.");
        var client = await ControlClient.LocateAsync();
        Task<JsonObject> Request(string verb, JsonObject input) => client.PostAsync("/v1/recall/" + verb, input);
        JsonObject response;
        if (action is "wait" or "meeting-wait")
            response = await RecallCommands.WaitAsync(body["id"]!.GetValue<string>(), action == "meeting-wait", false, timeout, Request);
        else
        {
            response = await Request(action, body);
            if (args.Wait) {
                bool meeting = action == "meeting-start";
                var id = response[meeting ? "meeting" : "job"]?["id"]?.GetValue<string>() ?? throw new InvalidOperationException("Recall did not return an ID.");
                response = await RecallCommands.WaitAsync(id, meeting, action == "prepare", timeout, Request);
            }
        }
        Output.Json(response);
        return response["ok"]?.GetValue<bool>() == false ? 1 : 0;
    }
}
