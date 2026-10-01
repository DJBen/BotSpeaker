using BotSpeaker;
using System.Net;

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

// Queue admission is synchronous up to the first await, making FIFO deterministic.
var queue = new SpeechSynthesisQueue(1);
await queue.AcquireAsync();
var first = queue.AcquireAsync();
using var cancellation = new CancellationTokenSource();
var cancelled = queue.AcquireAsync(cancellation.Token);
var last = queue.AcquireAsync();
cancellation.Cancel();
try { await cancelled.WaitAsync(TimeSpan.FromSeconds(2)); throw new Exception("Waiter was not cancelled"); }
catch (OperationCanceledException) { }
queue.Release();
await first.WaitAsync(TimeSpan.FromSeconds(2));
Check(!last.IsCompleted, "FIFO order was not preserved");
queue.Release();
await last.WaitAsync(TimeSpan.FromSeconds(2));
queue.Release();

using var handler = new SynthesisHandler();
using var http = new HttpClient(handler);
var cacheNamespace = "synthesis-test-" + Guid.NewGuid();
var cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BotSpeaker", "Audio", cacheNamespace);
try
{
    async Task<bool> Synthesize(int index, CancellationToken token = default)
    {
        try
        {
            await new ElevenLabsClient(http).SynthesizeAsync($"Speech {index}", "test", "test", "test", cacheNamespace, false, token);
            return true;
        }
        catch (HttpRequestException) { return false; }
    }

    // Fill all six slots, then cancel a waiting request before releasing the network.
    var requests = Enumerable.Range(0, 24).Select(i => Synthesize(i)).ToArray();
    await handler.SixStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
    using var waitingCancellation = new CancellationTokenSource();
    var waiting = Synthesize(100, waitingCancellation.Token);
    waitingCancellation.Cancel();
    try { await waiting.WaitAsync(TimeSpan.FromSeconds(2)); throw new Exception("Waiting synthesis was not cancelled"); }
    catch (OperationCanceledException) { }
    Check(handler.Started == 6, "Queued work reached the network too soon");
    handler.AllowCompletion.SetResult();
    var results = await Task.WhenAll(requests).WaitAsync(TimeSpan.FromSeconds(10));
    Check(results.Count(result => result) == 24, "Transient failure did not retry");
    Check(handler.Peak == 6 && handler.Started == 25 && handler.Active == 0, "Shared concurrency limit failed");

    // A completed clip must be served from cache without another network request.
    await Synthesize(23);
    Check(handler.Started == 25, "Cache hit reached the network");

    // Cancel an active request, then prove all six slots are still available.
    handler.AllowCompletion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    using var activeCancellation = new CancellationTokenSource();
    var active = Synthesize(101, activeCancellation.Token);
    Check(handler.Active == 1, "Active cancellation test never started");
    activeCancellation.Cancel();
    try { await active.WaitAsync(TimeSpan.FromSeconds(2)); throw new Exception("Active request was not cancelled"); }
    catch (OperationCanceledException) { }
    var next = Enumerable.Range(200, 6).Select(i => Synthesize(i)).ToArray();
    Check(handler.Active == 6, "Cancellation leaked a slot");
    handler.AllowCompletion.SetResult();
    await Task.WhenAll(next).WaitAsync(TimeSpan.FromSeconds(5));
    foreach (var statuses in new[] { new[] { 429, 503, 200 }, new[] { 503, 503, 503, 503, 200 },
                                    new[] { 400, 200 }, new[] { 401, 200 }, new[] { 403, 200 }, new[] { 422, 200 } })
    {
        using var retryHandler = new RetryHandler(statuses);
        using var retryHttp = new HttpClient(retryHandler);
        var delays = new List<TimeSpan>();
        var retryClient = new ElevenLabsClient(retryHttp, (delay, token) => { delays.Add(delay); return Task.CompletedTask; });
        try
        {
            await retryClient.SynthesizeAsync(Guid.NewGuid().ToString(), "test", "test", "test", cacheNamespace, false);
            Check(statuses[0] == 429 && retryHandler.Calls == 3, "Transient HTTP retry failed");
        }
        catch (AppException error)
        {
            Check(error.Message.Contains("fixture"), "Final API error was lost");
            Check(retryHandler.Calls == (statuses[0] == 503 ? 4 : 1), "Incorrect retry limit or permanent error retried");
        }
        Check(delays.All(d => d >= TimeSpan.FromSeconds(2)), "Retry-After seconds ignored");
    }
    using (var retryHandler = new RetryHandler([429, 200]))
    using (var retryHttp = new HttpClient(retryHandler))
    using (var backoffCancellation = new CancellationTokenSource())
    {
        var delayStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var retryClient = new ElevenLabsClient(retryHttp, async (_, token) => {
            delayStarted.SetResult();
            await Task.Delay(Timeout.Infinite, token);
        });
        var work = retryClient.SynthesizeAsync("cancel-backoff", "test", "test", "test", cacheNamespace, false, backoffCancellation.Token);
        await delayStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
        backoffCancellation.Cancel();
        try { await work.WaitAsync(TimeSpan.FromSeconds(2)); throw new Exception("Backoff ignored cancellation"); }
        catch (OperationCanceledException) { }
        Check(retryHandler.Calls == 1, "Cancelled backoff sent another request");
    }
    using (var response = new HttpResponseMessage(HttpStatusCode.TooManyRequests))
    {
        response.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(DateTimeOffset.UtcNow.AddSeconds(30));
        Check(ElevenLabsClient.RetryDelay(0, response).TotalSeconds > 28, "Retry-After date ignored");
    }
    for (var attempt = 0; attempt < 3; attempt++)
    {
        var delay = ElevenLabsClient.RetryDelay(attempt).TotalSeconds;
        Check(delay >= Math.Pow(2, attempt) && delay <= Math.Pow(2, attempt) + 0.25, "Incorrect backoff");
    }
    Console.WriteLine("PASS: HTTP retries, Retry-After seconds/date, backoff, permanent errors, exhaustion, backoff cancellation");
    Console.WriteLine("PASS: shared six-request limit, FIFO, waiting/active cancellation, failure recovery, and cache bypass");
}
finally
{
    handler.AllowCompletion.TrySetResult();
    if (Directory.Exists(cache)) Directory.Delete(cache, true);
}

sealed class SynthesisHandler : HttpMessageHandler
{
    public int Active;
    public int Peak;
    public int Started;
    public TaskCompletionSource SixStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource AllowCompletion = new(TaskCreationOptions.RunContinuationsAsynchronously);

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var number = Interlocked.Increment(ref Started);
        var current = Interlocked.Increment(ref Active);
        int old;
        do { old = Volatile.Read(ref Peak); }
        while (current > old && Interlocked.CompareExchange(ref Peak, current, old) != old);
        if (number == 6) SixStarted.TrySetResult();
        try
        {
            await AllowCompletion.Task.WaitAsync(cancellationToken);
            await Task.Delay(10, cancellationToken);
            if (number == 1) throw new HttpRequestException(HttpRequestError.ConnectionError, "Simulated network failure");
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{\"audio_base64\":\"YXVkaW8=\"}")
            };
        }
        finally { Interlocked.Decrement(ref Active); }
    }
}

sealed class RetryHandler(int[] statuses) : HttpMessageHandler
{
    public int Calls;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var status = statuses[Calls++];
        var response = new HttpResponseMessage((HttpStatusCode)status) {
            Content = new StringContent(status == 200 ? "{\"audio_base64\":\"YXVkaW8=\"}" : "{\"detail\":{\"message\":\"fixture\"}}")
        };
        response.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromSeconds(2));
        return Task.FromResult(response);
    }
}
