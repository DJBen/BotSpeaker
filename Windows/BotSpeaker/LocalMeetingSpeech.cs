using System.Text.Json.Nodes;
using System.Windows.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace BotSpeaker;

public sealed class LocalMeetingSpeech : IRecallMeetingSpeech
{
    private readonly AppModel model;
    private readonly Func<string, JsonObject, Task<JsonObject>> remote;
    private readonly string output, speechModel;
    private readonly CancellationTokenSource cancellation;
    private readonly Dictionary<string, (string Path, JsonObject State)> jobs = [];
    private WasapiOut? player;
    private AudioFileReader? audio;
    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    public LocalMeetingSpeech(AppModel model, Func<string, JsonObject, Task<JsonObject>> remote, CancellationToken token)
    {
        if (model.IsLocalPlaybackLocked || model.Player.IsPlaying || model.IsGenerating)
            throw new AppException("Stop local playback or leave the hosted meeting before starting host speech.");
        this.model = model; this.remote = remote;
        output = model.SelectedDeviceId; speechModel = model.ModelId;
        using var device = AudioDeviceManager.Device(output);
        if (device == null || device.State != DeviceState.Active) throw new AppException("Choose an available host output in Settings.");
        cancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
        model.IsRecallHostActive = true;
    }
    public async Task<JsonObject> HandleAsync(string action, JsonObject body)
    {
        if (action == "prepare" && body["botId"]?.GetValue<string>() == "local")
        {
            var key = new CredentialStore().Read();
            if (string.IsNullOrEmpty(key)) throw new AppException("Configure ElevenLabs before preparing host speech.");
            var clip = await new ElevenLabsClient().SynthesizeAsync(body["text"]!.GetValue<string>(), body["voice"]!.GetValue<string>(),
                speechModel, key, "recall-host", false, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            using var prepared = new AudioFileReader(clip.AudioPath);
            var id = "local-" + Guid.NewGuid();
            var state = new JsonObject { ["id"] = id, ["status"] = "prepared", ["durationSeconds"] = prepared.TotalTime.TotalSeconds };
            jobs.Add(id, (clip.AudioPath, state));
            return new() { ["job"] = state.DeepClone() };
        }
        if (body["id"]?.GetValue<string>() is string jobId && jobs.TryGetValue(jobId, out var job))
        {
            if (action == "cancel") { if (job.State["status"]?.GetValue<string>() == "dispatched") ReleasePlayer(); job.State["status"] = "cancelled"; }
            else if (action == "dispatch") {
                if (job.State["status"]?.GetValue<string>() != "prepared") throw new AppException("Host speech is no longer prepared.");
                cancellation.Token.ThrowIfCancellationRequested();
                ReleasePlayer();
                using var device = AudioDeviceManager.Device(output) ?? throw new AppException("Host output is no longer available.");
                if (device.State != DeviceState.Active) throw new AppException("Host output is no longer available.");
                audio = new AudioFileReader(job.Path) { Volume = (float)model.OutputVolume };
                player = new WasapiOut(device, AudioClientShareMode.Shared, true, 100);
                player.Init(audio);
                var activePlayer = player;
                player.PlaybackStopped += (_, args) => dispatcher.InvokeAsync(() => {
                    if (player != activePlayer || job.State["status"]?.GetValue<string>() != "dispatched") return;
                    job.State["status"] = args.Exception == null ? "finished_dispatching" : "failed";
                    if (args.Exception != null) job.State["error"] = args.Exception.Message;
                    ReleasePlayer();
                });
                job.State["status"] = "dispatched"; player.Play();
            }
            return new() { ["job"] = job.State.DeepClone() };
        }
        var result = await remote(action, body);
        if (action == "status") {
            var states = result["jobs"]!.AsArray();
            foreach (var entry in jobs.Values) states.Add(entry.State.DeepClone());
        }
        return result;
    }
    public void Dispose()
    {
        cancellation.Cancel();
        ReleasePlayer();
        foreach (var job in jobs.Values) job.State["status"] = "cancelled";
        jobs.Clear(); cancellation.Dispose(); model.IsRecallHostActive = false;
    }
    private void ReleasePlayer()
    {
        var previous = player; player = null; previous?.Dispose(); audio?.Dispose(); audio = null;
    }
}
