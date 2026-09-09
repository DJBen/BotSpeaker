using System.Text;
using System.Text.Json.Nodes;
using BotSpeaker.Cli;

// The `botspeaker` command for Windows: drives the running BotSpeaker app
// through its loopback control API. Subcommands, flags, output, and exit codes
// match the macOS CLI so scripts and agent skills work on both platforms.
//
// Exit codes: 0 success, 1 request failed, 2 app unreachable or usage error.

try { Console.OutputEncoding = Encoding.UTF8; } catch (IOException) { }
return await Cli.RunAsync(args);

static class Cli
{
    /// <summary>The command name as installed (botspeaker-cli.exe on Windows), for help text and hints.</summary>
    public static readonly string Name = Path.GetFileNameWithoutExtension(Environment.ProcessPath ?? "botspeaker-cli");

    private static readonly string[] AudioExtensions = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "wma", "flac", "ogg", "opus"];

    public static async Task<int> RunAsync(string[] args)
    {
        if (args.Length == 0) return await StatusAsync(new Args([], new()));
        var command = args[0].ToLowerInvariant();
        if (command is "--help" or "-h" or "help") { PrintHelp(); return 0; }
        if (command is "--version" or "-v" or "version") { Console.WriteLine(CliVersion.Current); return 0; }

        Args parsed;
        try
        {
            parsed = Args.Parse(args[1..]);
        }
        catch (UsageException error)
        {
            Console.Error.WriteLine($"error: {error.Message}");
            return 2;
        }
        if (parsed.Flag("help") || parsed.Flag("h"))
        {
            PrintHelp(command);
            return 0;
        }
        try
        {
            return command switch
            {
                "speak" => await SpeakAsync(parsed),
                "play-audio" or "play" => await PlayAudioAsync(parsed),
                "stop" => await StopAsync(parsed),
                "wait" => await WaitAsync(parsed),
                "requests" => await RequestsAsync(parsed),
                "status" => await StatusAsync(parsed),
                "targets" => await TargetsAsync(parsed),
                "voices" => await VoicesAsync(parsed),
                "outputs" => await OutputsAsync(parsed),
                "host" => await HostAsync(parsed),
                "join" => await JoinAsync(parsed),
                "leave" => await LeaveAsync(parsed),
                _ => Unknown(command),
            };
        }
        catch (UsageException error)
        {
            Console.Error.WriteLine($"error: {error.Message}");
            return 2;
        }
        catch (Exception error)
        {
            return Output.Fail(error, parsed.Json);
        }
    }

    private static int Unknown(string command)
    {
        Console.Error.WriteLine($"error: unknown command \"{command}\". Run `{Name} --help`.");
        return 2;
    }

    // speak

    private static async Task<int> SpeakAsync(Args args)
    {
        var (loop, repeatCount) = args.Cycles();
        var text = ResolveText(args);
        var client = await ControlClient.LocateAsync();
        var body = new JsonObject
        {
            ["text"] = text,
            ["target"] = args.Option("target", "t") ?? "local",
            ["wait"] = args.Wait,
            ["timeout"] = args.Timeout,
            ["loop"] = loop,
        };
        if (repeatCount is int count) body["repeat"] = count;
        if (args.Option("voice", "v") is string voice) body["voice"] = voice;
        var response = await client.PostAsync("/v1/speak", body);
        return ReportQueued(response, args, loop, describeTarget: true);
    }

    private static string ResolveText(Args args)
    {
        if (args.Option("file", "f") is string file)
        {
            var data = file == "-" ? ReadStdin() : File.ReadAllText(file, Encoding.UTF8);
            return data;
        }
        var joined = string.Join(" ", args.Positional);
        if (joined.Trim().Length > 0) return joined;
        if (Console.IsInputRedirected)
        {
            var piped = ReadStdin();
            if (piped.Trim().Length > 0) return piped;
        }
        throw new ControlClient.Failure(1, "bad_input", "Give the text as an argument, via --file, or on stdin.");
    }

    private static string ReadStdin()
    {
        using var reader = new StreamReader(Console.OpenStandardInput(), Encoding.UTF8);
        return reader.ReadToEnd();
    }

    // play-audio

    private static async Task<int> PlayAudioAsync(Args args)
    {
        var (loop, repeatCount) = args.Cycles();
        if (args.Positional.Count != 1) throw new UsageException("play-audio takes exactly one argument: the path to an audio file.");
        var path = Path.GetFullPath(args.Positional[0]);
        if (!File.Exists(path)) throw new UsageException($"No file at {path}.");
        var extension = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        if (!AudioExtensions.Contains(extension))
        {
            throw new UsageException($"{Path.GetFileName(path)} is not a supported audio file. Use one of: {string.Join(", ", AudioExtensions)}.");
        }
        var data = await File.ReadAllBytesAsync(path);
        if (data.Length == 0) throw new ControlClient.Failure(1, "bad_input", $"{Path.GetFileName(path)} is empty.");
        var client = await ControlClient.LocateAsync();
        var body = new JsonObject
        {
            ["audio"] = Convert.ToBase64String(data),
            ["filename"] = Path.GetFileName(path),
            ["target"] = "local",
            ["wait"] = args.Wait,
            ["timeout"] = args.Timeout,
            ["loop"] = loop,
        };
        if (repeatCount is int count) body["repeat"] = count;
        var response = await client.PostAsync("/v1/play-audio", body);
        return ReportQueued(response, args, loop, describeTarget: false);
    }

    private static int ReportQueued(JsonObject response, Args args, bool loop, bool describeTarget)
    {
        var request = response["request"] as JsonObject ?? [];
        if (args.Json)
        {
            Output.Json(response);
        }
        else
        {
            var status = Output.String(request["status"]);
            var id = Output.String(request["id"]);
            var subject = describeTarget ? $"on {Output.String(request["targetName"])}" : Output.String(request["audioFile"] ?? request["text"]);
            var passes = Output.Cycles(request) is string cycles ? $" [{cycles}]" : "";
            if (args.Wait)
            {
                var detail = Output.String(request["error"]);
                Console.WriteLine($"{status} {subject}{passes} ({id}){(detail == "-" ? "" : $": {detail}")}");
            }
            else if (loop)
            {
                Console.WriteLine($"{status} {subject}{passes} ({id}) — loops until `{Name} stop {id}`");
            }
            else
            {
                Console.WriteLine($"{status} {subject}{passes} ({id}) — use `{Name} wait {id}` to follow it");
            }
        }
        return args.Wait && Output.String(request["status"]) != "completed" ? 1 : 0;
    }

    // stop / wait / requests

    private static async Task<int> StopAsync(Args args)
    {
        var client = await ControlClient.LocateAsync();
        var id = args.Positional.FirstOrDefault()?.Trim();
        var response = string.IsNullOrEmpty(id)
            ? await client.PostAsync("/v1/speech/cancel-all")
            : await client.PostAsync($"/v1/speech/{Uri.EscapeDataString(id)}/cancel");
        if (args.Json) Output.Json(response);
        else if (response["request"] is JsonObject request) Console.WriteLine($"{Output.String(request["status"])} ({Output.String(request["id"])})");
        else Console.WriteLine("cancelled all pending speech");
        return 0;
    }

    private static async Task<int> WaitAsync(Args args)
    {
        if (args.Positional.Count != 1) throw new UsageException("wait takes exactly one argument: the request ID from `speak`.");
        var client = await ControlClient.LocateAsync();
        var response = await client.GetAsync($"/v1/speech/{Uri.EscapeDataString(args.Positional[0])}", new()
        {
            ["wait"] = "1",
            ["timeout"] = args.Timeout.ToString(System.Globalization.CultureInfo.InvariantCulture),
        });
        var request = response["request"] as JsonObject ?? [];
        if (args.Json) Output.Json(response);
        else
        {
            var detail = Output.String(request["error"]);
            var passes = Output.Cycles(request) is string cycles ? $" [{cycles}]" : "";
            Console.WriteLine($"{Output.String(request["status"])} on {Output.String(request["targetName"])}{passes}{(detail == "-" ? "" : $": {detail}")}");
        }
        return Output.String(request["status"]) == "completed" ? 0 : 1;
    }

    private static async Task<int> RequestsAsync(Args args)
    {
        var client = await ControlClient.LocateAsync();
        var response = await client.GetAsync("/v1/speech");
        if (args.Json) { Output.Json(response); return 0; }
        var requests = response["requests"] as JsonArray ?? new JsonArray();
        if (requests.Count == 0) { Console.WriteLine("no speech requests yet"); return 0; }
        var rows = new List<string[]> { new[] { "ID", "STATUS", "TARGET", "PASSES", "TEXT" } };
        foreach (var node in requests)
        {
            if (node is not JsonObject request) continue;
            var text = Output.String(request["text"]).Replace('\n', ' ');
            rows.Add([
                Output.String(request["id"]),
                Output.String(request["status"]),
                Output.String(request["targetName"]),
                Output.Cycles(request) ?? "1",
                text.Length > 60 ? text[..60] : text,
            ]);
        }
        Output.Table(rows);
        return 0;
    }

    // status / targets / voices / outputs

    private static async Task<int> StatusAsync(Args args)
    {
        var client = await ControlClient.LocateAsync();
        var response = await client.GetAsync("/v1/status");
        if (args.Json) { Output.Json(response); return 0; }
        var app = response["app"] as JsonObject ?? [];
        Console.WriteLine($"BotSpeaker {Output.String(app["version"])} (pid {Output.String(app["pid"])}) at {client.BaseUrl}");
        Console.WriteLine($"API key: {Output.String(response["apiKeyConfigured"])}");
        Console.WriteLine(response["output"] is JsonObject output ? $"Output: {Output.String(output["name"])}" : "Output: none selected");
        if (response["voice"] is JsonObject voice) Console.WriteLine($"Voice: {Output.String(voice["name"])} ({Output.String(voice["id"])})");
        if (response["session"] is JsonObject session)
        {
            Console.WriteLine($"Session: {Output.String(session["mode"])} · code {Output.String(session["code"])} · {Output.String(session["status"])}");
            foreach (var node in session["attendees"] as JsonArray ?? new JsonArray())
            {
                if (node is not JsonObject attendee) continue;
                var mark = Output.Bool(attendee["isThisMac"]) == true ? " (this machine)" : "";
                var connected = Output.Bool(attendee["connected"]) == true ? "connected" : "offline";
                Console.WriteLine($"  - {Output.String(attendee["name"])}{mark}: {connected} [{Output.String(attendee["id"])}]");
            }
        }
        else
        {
            Console.WriteLine($"Session: none (run `{Name} host` or `{Name} join CODE`)");
        }
        if (response["activeSpeech"] is JsonObject active)
        {
            Console.WriteLine($"Speaking: {Output.String(active["status"])} on {Output.String(active["targetName"])} ({Output.String(active["id"])})");
        }
        return 0;
    }

    private static async Task<int> TargetsAsync(Args args)
    {
        var client = await ControlClient.LocateAsync();
        var response = await client.GetAsync("/v1/targets");
        if (args.Json) { Output.Json(response); return 0; }
        var rows = new List<string[]> { new[] { "ID", "NAME", "KIND", "CONNECTED" } };
        foreach (var node in response["targets"] as JsonArray ?? new JsonArray())
        {
            if (node is not JsonObject target) continue;
            rows.Add([Output.String(target["id"]), Output.String(target["name"]), Output.String(target["kind"]), Output.String(target["connected"])]);
        }
        Output.Table(rows);
        return 0;
    }

    private static async Task<int> VoicesAsync(Args args)
    {
        var client = await ControlClient.LocateAsync();
        if (args.Option("select") is string select)
        {
            var selected = await client.PostAsync("/v1/voices/select", new JsonObject { ["voice"] = select });
            if (args.Json) Output.Json(selected);
            else if (selected["selected"] is JsonObject chosen) Console.WriteLine($"selected {Output.String(chosen["name"])} ({Output.String(chosen["id"])})");
            return 0;
        }
        var response = await client.GetAsync("/v1/voices", args.Flag("refresh") ? new() { ["refresh"] = "1" } : null);
        if (args.Json) { Output.Json(response); return 0; }
        var current = Output.String(response["selected"]);
        var rows = new List<string[]> { new[] { "", "ID", "NAME", "DETAIL" } };
        foreach (var node in response["voices"] as JsonArray ?? new JsonArray())
        {
            if (node is not JsonObject voice) continue;
            rows.Add([Output.String(voice["id"]) == current ? "*" : " ", Output.String(voice["id"]), Output.String(voice["name"]), Output.String(voice["detail"])]);
        }
        Output.Table(rows);
        return 0;
    }

    private static async Task<int> OutputsAsync(Args args)
    {
        var client = await ControlClient.LocateAsync();
        if (args.Option("select") is string select)
        {
            var selected = await client.PostAsync("/v1/outputs/select", new JsonObject { ["name"] = select });
            if (args.Json) Output.Json(selected);
            else if (selected["selected"] is JsonObject chosen) Console.WriteLine($"selected {Output.String(chosen["name"])}");
            return 0;
        }
        var response = await client.GetAsync("/v1/outputs");
        if (args.Json) { Output.Json(response); return 0; }
        var rows = new List<string[]> { new[] { "", "NAME", "UID" } };
        foreach (var node in response["outputs"] as JsonArray ?? new JsonArray())
        {
            if (node is not JsonObject output) continue;
            rows.Add([Output.Bool(output["selected"]) == true ? "*" : " ", Output.String(output["name"]), Output.String(output["uid"])]);
        }
        Output.Table(rows);
        return 0;
    }

    // host / join / leave

    private static async Task<int> HostAsync(Args args)
    {
        var client = await ControlClient.LocateAsync();
        var body = new JsonObject();
        if (args.Option("name") is string name) body["speakerName"] = name;
        var response = await client.PostAsync("/v1/session/host", body);
        if (args.Json) Output.Json(response);
        else if (response["session"] is JsonObject session) Console.WriteLine($"hosting · pairing code {Output.String(session["code"])}");
        return 0;
    }

    private static async Task<int> JoinAsync(Args args)
    {
        if (args.Positional.Count != 1) throw new UsageException("join takes exactly one argument: the six-character pairing code.");
        var client = await ControlClient.LocateAsync();
        var body = new JsonObject { ["code"] = args.Positional[0] };
        if (args.Option("name") is string name) body["speakerName"] = name;
        var response = await client.PostAsync("/v1/session/join", body);
        if (args.Json) Output.Json(response);
        else if (response["session"] is JsonObject session) Console.WriteLine($"joined · code {Output.String(session["code"])} · {Output.String(session["status"])}");
        return 0;
    }

    private static async Task<int> LeaveAsync(Args args)
    {
        var client = await ControlClient.LocateAsync();
        var response = await client.PostAsync("/v1/session/leave");
        if (args.Json) Output.Json(response); else Console.WriteLine("left the meeting");
        return 0;
    }

    // help

    private static void PrintHelp(string? command = null)
    {
        var help = command switch
        {
            "speak" => $"""
                USAGE: {Name} speak [--target NAME] [--voice NAME] [--wait] [--timeout SECONDS] [--file PATH|-] [--loop | --repeat N] [--json] [--] [TEXT ...]

                Speak text on this PC or on a paired attendee (host only).
                  -t, --target NAME    "local" (default), an attendee name, or an attendee UID
                  -v, --voice NAME     voice name or ElevenLabs voice ID; defaults to the target's configured voice
                  -w, --wait           block until playback finishes; exit 0 only when it completed
                      --timeout SECS   seconds to wait when --wait is set (default 600)
                  -f, --file PATH      read the text from a file ("-" for stdin)
                  -l, --loop           play on a cycle until `{Name} stop`
                  -r, --repeat N       play N times
                      --json           machine-readable output
                """,
            "play-audio" or "play" => $"""
                USAGE: {Name} play-audio [--wait] [--timeout SECONDS] [--loop | --repeat N] [--json] FILE

                Play an audio file (mp3, wav, m4a, aac, aiff, wma, flac, ogg, opus) through BotSpeaker's output on this PC.
                The file is uploaded to the running app and queued like spoken text, so --wait, `{Name} stop`,
                and `{Name} requests` all apply. Audio files play locally only.
                """,
            _ => $"""
                {Name} {CliVersion.Current} — drive the BotSpeaker app from the command line.

                USAGE: {Name} <command> [options]

                COMMANDS
                  status                       app, output, voice, session, active speech (default)
                  speak [options] TEXT         speak text on this PC or on a paired attendee
                  play-audio [options] FILE    play a recorded audio file on this PC
                  stop [ID]                    cancel one request, or everything queued and playing
                  wait ID [--timeout SECS]     follow a request started without --wait
                  requests                     recent requests with status
                  targets                      "local" plus attendees paired to the meeting this PC hosts
                  voices [--refresh] [--select NAME]
                  outputs [--select NAME]
                  host [--name NAME]           start hosting; prints the pairing code
                  join CODE [--name NAME]      pair this PC to a host
                  leave                        leave the meeting (ends it when this PC hosts)

                Add --json to any command for machine-readable output. Run `{Name} speak --help` for speak options.
                The CLI launches BotSpeaker in the background if it is not running (set BOTSPEAKER_NO_LAUNCH=1 to fail instead,
                BOTSPEAKER_APP to pick a specific BotSpeaker.exe). Exit codes: 0 success, 1 request failed, 2 app unreachable.
                """,
        };
        Console.WriteLine(help);
    }
}

sealed class UsageException(string message) : Exception(message);

/// <summary>Minimal option parser: --name value, --name=value, -n value, boolean flags, and "--" to end options.</summary>
sealed class Args(List<string> positional, Dictionary<string, string?> options)
{
    private static readonly HashSet<string> BooleanFlags = ["json", "wait", "w", "loop", "l", "refresh", "help", "h"];

    public List<string> Positional { get; } = positional;
    private Dictionary<string, string?> Options { get; } = options;

    public bool Json => Flag("json");
    public bool Wait => Flag("wait") || Flag("w");
    public double Timeout => Option("timeout") is string text
        ? double.TryParse(text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var seconds) && seconds > 0
            ? seconds
            : throw new UsageException("--timeout must be a positive number of seconds.")
        : 600;

    public bool Flag(string name) => Options.ContainsKey(name);

    public string? Option(string name, string? shortName = null) =>
        Options.TryGetValue(name, out var value) && value is not null ? value
        : shortName is not null && Options.TryGetValue(shortName, out var shortValue) ? shortValue
        : null;

    public (bool Loop, int? Repeat) Cycles()
    {
        bool loop = Flag("loop") || Flag("l");
        int? repeat = null;
        if (Option("repeat", "r") is string text)
        {
            if (!int.TryParse(text, out var count) || count < 1) throw new UsageException("--repeat must be at least 1.");
            repeat = count;
        }
        if (loop && repeat is not null) throw new UsageException("Use either --loop or --repeat, not both.");
        return (loop, repeat);
    }

    public static Args Parse(string[] args)
    {
        var positional = new List<string>();
        var options = new Dictionary<string, string?>();
        for (int index = 0; index < args.Length; index++)
        {
            var arg = args[index];
            if (arg == "--")
            {
                positional.AddRange(args[(index + 1)..]);
                break;
            }
            if (arg.StartsWith("--") || (arg.Length == 2 && arg[0] == '-' && char.IsLetter(arg[1])))
            {
                var name = arg.TrimStart('-');
                string? value = null;
                int equals = name.IndexOf('=');
                if (equals >= 0)
                {
                    value = name[(equals + 1)..];
                    name = name[..equals];
                }
                else if (!BooleanFlags.Contains(name))
                {
                    if (index + 1 >= args.Length) throw new UsageException($"--{name} needs a value.");
                    value = args[++index];
                }
                options[name] = value;
                continue;
            }
            positional.Add(arg);
        }
        return new Args(positional, options);
    }
}
