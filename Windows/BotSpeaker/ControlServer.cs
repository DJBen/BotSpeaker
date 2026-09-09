using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows.Threading;

namespace BotSpeaker;

/// <summary>
/// A minimal loopback HTTP/1.1 server that exposes the app to local tooling
/// (the <c>botspeaker</c> CLI and anything that can run <c>curl</c>) — the
/// Windows counterpart of the macOS ControlServer. It binds 127.0.0.1 only,
/// requires a per-launch bearer token, and publishes a discovery file so
/// clients find the port and token without configuration. A raw
/// <see cref="TcpListener"/> is used instead of HttpListener so no URL
/// reservation (admin rights) is needed.
/// </summary>
public sealed class ControlServer
{
    public sealed record Request(string Method, string Path, Dictionary<string, string> Query, Dictionary<string, string> Headers, byte[] Body)
    {
        public JsonObject? Json()
        {
            if (Body.Length == 0) return null;
            try { return JsonNode.Parse(Body) as JsonObject; } catch (Exception) { return null; }
        }
    }

    public sealed record Response(int Status, JsonNode Body)
    {
        public static Response Ok(JsonObject body) => new(200, body);
        public static Response Error(int status, string message, string code = "error") =>
            new(status, new JsonObject
            {
                ["ok"] = false,
                ["error"] = new JsonObject { ["code"] = code, ["message"] = message },
            });
    }

    public const int DefaultPort = 47311;
    private const int MaximumBodySize = 64 * 1024 * 1024;

    public int Port { get; private set; }
    public string Token { get; }
    public string? LastError { get; private set; }

    public static string DiscoveryDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "BotSpeaker");
    public static string DiscoveryFilePath => Path.Combine(DiscoveryDirectory, "control.json");

    private readonly Func<Request, Task<Response>> _handler;
    private readonly Dispatcher _dispatcher;
    private readonly string _version;
    private TcpListener? _listener;
    private CancellationTokenSource? _lifetime;

    public ControlServer(Dispatcher dispatcher, string version, Func<Request, Task<Response>> handler)
    {
        _dispatcher = dispatcher;
        _version = version;
        _handler = handler;
        Token = Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
    }

    public void Start(int preferredPort)
    {
        var requested = preferredPort > 0 ? preferredPort : DefaultPort;
        if (!TryListen(requested) && !TryListen(0)) return;
        WriteDiscoveryFile();
        _lifetime = new CancellationTokenSource();
        _ = AcceptLoopAsync(_listener!, _lifetime.Token);
    }

    public void Stop()
    {
        _lifetime?.Cancel();
        _listener?.Stop();
        _listener = null;
        try { File.Delete(DiscoveryFilePath); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private bool TryListen(int port)
    {
        try
        {
            var listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            _listener = listener;
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            LastError = null;
            return true;
        }
        catch (SocketException error)
        {
            LastError = error.Message;
            return false;
        }
    }

    private void WriteDiscoveryFile()
    {
        try
        {
            Directory.CreateDirectory(DiscoveryDirectory);
            var payload = new JsonObject
            {
                ["url"] = $"http://127.0.0.1:{Port}",
                ["port"] = Port,
                ["token"] = Token,
                ["pid"] = Environment.ProcessId,
                ["version"] = _version,
                ["platform"] = "windows",
                // Lets the CLI relaunch this exact copy later, wherever the
                // user keeps it.
                ["exe"] = Environment.ProcessPath,
            };
            File.WriteAllText(DiscoveryFilePath, payload.ToJsonString(new() { WriteIndented = true }));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            LastError = error.Message;
        }
    }

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken cancellation)
    {
        while (!cancellation.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync(cancellation);
            }
            catch (Exception) when (cancellation.IsCancellationRequested)
            {
                return;
            }
            catch (Exception)
            {
                continue;
            }
            _ = Task.Run(() => ServeAsync(client, cancellation), cancellation);
        }
    }

    private async Task ServeAsync(TcpClient client, CancellationToken cancellation)
    {
        using (client)
        {
            client.NoDelay = true;
            using var stream = client.GetStream();
            Request? request;
            try
            {
                request = await ReadRequestAsync(stream, cancellation);
            }
            catch (RequestTooLargeException)
            {
                await WriteResponseAsync(stream, Response.Error(413, "Request too large", "too_large"), cancellation);
                return;
            }
            catch (Exception)
            {
                return;
            }
            if (request is null)
            {
                await WriteResponseAsync(stream, Response.Error(400, "Malformed request", "bad_request"), cancellation);
                return;
            }

            Response response;
            if (request.Path == "/health")
            {
                response = Response.Ok(new JsonObject { ["ok"] = true, ["pid"] = Environment.ProcessId, ["version"] = _version });
            }
            else if (!IsAuthorized(request))
            {
                response = Response.Error(401, "Missing or invalid control token. Read it from control.json.", "unauthorized");
            }
            else
            {
                try
                {
                    // The model and controller are UI-thread objects; hop over and stay
                    // there for the whole (possibly long-polling) handler.
                    response = await _dispatcher.InvokeAsync(() => _handler(request)).Task.Unwrap();
                }
                catch (Exception error)
                {
                    response = Response.Error(500, error.Message, "internal");
                }
            }
            await WriteResponseAsync(stream, response, cancellation);
        }
    }

    private bool IsAuthorized(Request request)
    {
        if (request.Headers.TryGetValue("authorization", out var authorization)
            && authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
            && FixedTimeEquals(authorization["Bearer ".Length..].Trim(), Token))
        {
            return true;
        }
        return request.Headers.TryGetValue("x-botspeaker-token", out var header) && FixedTimeEquals(header.Trim(), Token);
    }

    private static bool FixedTimeEquals(string a, string b) =>
        CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(a), Encoding.UTF8.GetBytes(b));

    private sealed class RequestTooLargeException : Exception;

    private static async Task<Request?> ReadRequestAsync(NetworkStream stream, CancellationToken cancellation)
    {
        var buffer = new MemoryStream();
        var chunk = new byte[65536];
        int headerEnd = -1;
        while (headerEnd < 0)
        {
            int read = await stream.ReadAsync(chunk, cancellation);
            if (read == 0) return null;
            buffer.Write(chunk, 0, read);
            headerEnd = IndexOfHeaderEnd(buffer.GetBuffer(), (int)buffer.Length);
            if (headerEnd < 0 && buffer.Length > 65536) return null;
        }

        var headerText = Encoding.ASCII.GetString(buffer.GetBuffer(), 0, headerEnd);
        var lines = headerText.Split("\r\n");
        var requestLine = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (requestLine.Length < 2) return null;
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            int colon = line.IndexOf(':');
            if (colon <= 0) continue;
            headers[line[..colon].Trim().ToLowerInvariant()] = line[(colon + 1)..].Trim();
        }
        int contentLength = headers.TryGetValue("content-length", out var lengthText) && int.TryParse(lengthText, out var length) ? length : 0;
        if (contentLength > MaximumBodySize) throw new RequestTooLargeException();

        int bodyStart = headerEnd + 4;
        while (buffer.Length - bodyStart < contentLength)
        {
            int read = await stream.ReadAsync(chunk, cancellation);
            if (read == 0) return null;
            buffer.Write(chunk, 0, read);
        }
        var body = new byte[contentLength];
        Array.Copy(buffer.GetBuffer(), bodyStart, body, 0, contentLength);

        var target = requestLine[1];
        var path = target;
        var query = new Dictionary<string, string>();
        int question = target.IndexOf('?');
        if (question >= 0)
        {
            path = target[..question];
            foreach (var pair in target[(question + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                int equals = pair.IndexOf('=');
                var key = Uri.UnescapeDataString(equals < 0 ? pair : pair[..equals]);
                var value = equals < 0 ? "" : Uri.UnescapeDataString(pair[(equals + 1)..].Replace('+', ' '));
                query[key] = value;
            }
        }
        return new Request(requestLine[0].ToUpperInvariant(), path.Length == 0 ? "/" : path, query, headers, body);
    }

    private static int IndexOfHeaderEnd(byte[] data, int length)
    {
        for (int index = 0; index + 3 < length; index++)
        {
            if (data[index] == '\r' && data[index + 1] == '\n' && data[index + 2] == '\r' && data[index + 3] == '\n') return index;
        }
        return -1;
    }

    private static async Task WriteResponseAsync(NetworkStream stream, Response response, CancellationToken cancellation)
    {
        var body = Encoding.UTF8.GetBytes(response.Body.ToJsonString());
        var reason = response.Status switch
        {
            200 => "OK",
            202 => "Accepted",
            400 => "Bad Request",
            401 => "Unauthorized",
            404 => "Not Found",
            409 => "Conflict",
            413 => "Payload Too Large",
            _ => response.Status >= 500 ? "Internal Server Error" : "Error",
        };
        var head = $"HTTP/1.1 {response.Status} {reason}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {body.Length}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n";
        try
        {
            await stream.WriteAsync(Encoding.ASCII.GetBytes(head), cancellation);
            await stream.WriteAsync(body, cancellation);
            await stream.FlushAsync(cancellation);
        }
        catch (IOException)
        {
        }
    }
}
