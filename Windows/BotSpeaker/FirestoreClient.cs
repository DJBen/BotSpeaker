using System.Globalization;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BotSpeaker;

/// <summary>
/// Public Firebase client configuration for project bot-speaker-1 — the same
/// values GoogleService-Info.plist provides to the macOS app. The API key
/// identifies the project and grants no database access; anonymous
/// authentication plus firestore.rules enforce access.
/// </summary>
public static class FirebaseConfig
{
    public const string ApiKey = "AIzaSyD4hzRZ2jMLE4zr3AJ6pau_3-ZI3Y6MS74";
    public const string ProjectId = "bot-speaker-1";
    public const string DatabaseId = "(default)";

    public static string DocumentsRoot =>
        $"https://firestore.googleapis.com/v1/projects/{ProjectId}/databases/{DatabaseId}/documents";

    public static string DocumentResourcePrefix =>
        $"projects/{ProjectId}/databases/{DatabaseId}/documents";
}

/// <summary>A decoded Firestore document: its path-relative ID plus flattened field values.</summary>
public sealed record FirestoreDocument(string Id, Dictionary<string, object?> Fields)
{
    public string? String(string field) => Fields.GetValueOrDefault(field) as string;
    public bool Bool(string field) => Fields.GetValueOrDefault(field) as bool? ?? false;
    public int Int(string field, int fallback = 0) =>
        Fields.GetValueOrDefault(field) is long value ? (int)value : fallback;
    public DateTime? Timestamp(string field) => Fields.GetValueOrDefault(field) as DateTime?;
}

/// <summary>One write inside a Firestore commit; supports REQUEST_TIME field transforms.</summary>
public sealed class FirestoreWrite
{
    public required string DocumentPath { get; init; }
    public Dictionary<string, object?> Fields { get; init; } = [];
    /// <summary>Field paths to replace. Null merges nothing selectively — the whole document is set.</summary>
    public List<string>? UpdateMask { get; init; }
    public List<string> ServerTimestampFields { get; init; } = [];
    /// <summary>Precondition: true requires the document to exist, false requires it to be absent.</summary>
    public bool? MustExist { get; init; }
}

/// <summary>
/// Minimal Firestore + Firebase Auth REST client. The macOS app uses the
/// Firebase SDK; Windows speaks the same documented REST protocol that
/// scripts/test-orchestration-backend.sh exercises, so both clients satisfy the
/// identical firestore.rules (server-time transforms included).
/// </summary>
public sealed class FirestoreClient
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    private string? _idToken;
    private string? _refreshToken;
    private DateTime _tokenExpiry = DateTime.MinValue;

    public string? UserId { get; private set; }

    /// <summary>Signs in anonymously (or refreshes the cached token) and returns the stable UID.</summary>
    public async Task<string> EnsureSignedInAsync(CancellationToken cancellation = default)
    {
        if (UserId is string uid && _idToken is not null)
        {
            if (DateTime.UtcNow < _tokenExpiry - TimeSpan.FromMinutes(5)) return uid;
            if (_refreshToken is not null)
            {
                await RefreshTokenAsync(cancellation);
                return UserId!;
            }
        }

        using var response = await Http.PostAsJsonAsync(
            $"https://identitytoolkit.googleapis.com/v1/accounts:signUp?key={FirebaseConfig.ApiKey}",
            new { returnSecureToken = true },
            cancellation);
        var body = await ReadJsonAsync(response, "Anonymous sign-in failed", cancellation);
        _idToken = body["idToken"]?.GetValue<string>()
            ?? throw new AppException("Anonymous sign-in returned no token.");
        _refreshToken = body["refreshToken"]?.GetValue<string>();
        UserId = body["localId"]?.GetValue<string>()
            ?? throw new AppException("Anonymous sign-in returned no user ID.");
        _tokenExpiry = DateTime.UtcNow + ParseExpiry(body["expiresIn"]?.GetValue<string>());
        return UserId;
    }

    private async Task RefreshTokenAsync(CancellationToken cancellation)
    {
        using var response = await Http.PostAsync(
            $"https://securetoken.googleapis.com/v1/token?key={FirebaseConfig.ApiKey}",
            new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["grant_type"] = "refresh_token",
                ["refresh_token"] = _refreshToken!,
            }),
            cancellation);
        var body = await ReadJsonAsync(response, "Session refresh failed", cancellation);
        _idToken = body["id_token"]?.GetValue<string>() ?? _idToken;
        _refreshToken = body["refresh_token"]?.GetValue<string>() ?? _refreshToken;
        UserId = body["user_id"]?.GetValue<string>() ?? UserId;
        _tokenExpiry = DateTime.UtcNow + ParseExpiry(body["expires_in"]?.GetValue<string>());
    }

    private static TimeSpan ParseExpiry(string? seconds) =>
        TimeSpan.FromSeconds(double.TryParse(seconds, NumberStyles.Any, CultureInfo.InvariantCulture, out var value)
            ? Math.Max(value, 300)
            : 3600);

    public async Task<FirestoreDocument?> GetDocumentAsync(string path, CancellationToken cancellation = default)
    {
        using var request = await AuthorizedRequestAsync(HttpMethod.Get, $"{FirebaseConfig.DocumentsRoot}/{path}", cancellation);
        using var response = await Http.SendAsync(request, cancellation);
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        var body = await ReadJsonAsync(response, "The meeting service rejected a read", cancellation);
        return DecodeDocument(body);
    }

    public async Task<List<FirestoreDocument>> ListDocumentsAsync(string collectionPath, CancellationToken cancellation = default)
    {
        var documents = new List<FirestoreDocument>();
        string? pageToken = null;
        do
        {
            var url = $"{FirebaseConfig.DocumentsRoot}/{collectionPath}?pageSize=300";
            if (pageToken is not null) url += "&pageToken=" + Uri.EscapeDataString(pageToken);
            using var request = await AuthorizedRequestAsync(HttpMethod.Get, url, cancellation);
            using var response = await Http.SendAsync(request, cancellation);
            var body = await ReadJsonAsync(response, "The meeting service rejected a read", cancellation);
            if (body["documents"] is JsonArray array)
            {
                foreach (var node in array)
                {
                    if (node is JsonObject document) documents.Add(DecodeDocument(document));
                }
            }
            pageToken = body["nextPageToken"]?.GetValue<string>();
        } while (pageToken is not null);
        return documents;
    }

    /// <summary>Commits one or more writes atomically — the REST analog of a Firestore SDK batch.</summary>
    public async Task CommitAsync(IReadOnlyList<FirestoreWrite> writes, CancellationToken cancellation = default)
    {
        var writeNodes = new JsonArray();
        foreach (var write in writes)
        {
            var update = new JsonObject
            {
                ["name"] = $"{FirebaseConfig.DocumentResourcePrefix}/{write.DocumentPath}",
                ["fields"] = EncodeFields(write.Fields),
            };
            var node = new JsonObject { ["update"] = update };
            if (write.UpdateMask is not null)
            {
                node["updateMask"] = new JsonObject
                {
                    ["fieldPaths"] = new JsonArray([.. write.UpdateMask.Select(f => JsonValue.Create(f))]),
                };
            }
            if (write.ServerTimestampFields.Count > 0)
            {
                node["updateTransforms"] = new JsonArray([.. write.ServerTimestampFields.Select(field =>
                    (JsonNode)new JsonObject
                    {
                        ["fieldPath"] = field,
                        ["setToServerValue"] = "REQUEST_TIME",
                    })]);
            }
            if (write.MustExist is bool exists)
            {
                node["currentDocument"] = new JsonObject { ["exists"] = exists };
            }
            writeNodes.Add(node);
        }

        var payload = new JsonObject { ["writes"] = writeNodes };
        using var request = await AuthorizedRequestAsync(
            HttpMethod.Post,
            $"https://firestore.googleapis.com/v1/projects/{FirebaseConfig.ProjectId}/databases/{FirebaseConfig.DatabaseId}/documents:commit",
            cancellation);
        request.Content = new StringContent(payload.ToJsonString(), System.Text.Encoding.UTF8, "application/json");
        using var response = await Http.SendAsync(request, cancellation);
        await ReadJsonAsync(response, "The meeting service rejected a write", cancellation);
    }

    public Task CommitAsync(FirestoreWrite write, CancellationToken cancellation = default) =>
        CommitAsync([write], cancellation);

    private async Task<HttpRequestMessage> AuthorizedRequestAsync(HttpMethod method, string url, CancellationToken cancellation)
    {
        await EnsureSignedInAsync(cancellation);
        var request = new HttpRequestMessage(method, url);
        request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", _idToken);
        return request;
    }

    private static async Task<JsonObject> ReadJsonAsync(HttpResponseMessage response, string failure, CancellationToken cancellation)
    {
        var text = await response.Content.ReadAsStringAsync(cancellation);
        if (!response.IsSuccessStatusCode)
        {
            string? detail = null;
            try
            {
                var error = JsonNode.Parse(text);
                detail = error?["error"]?["message"]?.GetValue<string>();
            }
            catch (JsonException)
            {
            }
            throw new AppException($"{failure} ({(int)response.StatusCode}{(detail is null ? "" : $": {detail}")}).");
        }
        try
        {
            return JsonNode.Parse(text) as JsonObject ?? [];
        }
        catch (JsonException)
        {
            throw new AppException($"{failure} (invalid response).");
        }
    }

    // Firestore value encoding

    public static JsonObject EncodeFields(Dictionary<string, object?> fields)
    {
        var result = new JsonObject();
        foreach (var (key, value) in fields)
        {
            result[key] = EncodeValue(value);
        }
        return result;
    }

    private static JsonObject EncodeValue(object? value) => value switch
    {
        null => new JsonObject { ["nullValue"] = "NULL_VALUE" },
        string text => new JsonObject { ["stringValue"] = text },
        bool flag => new JsonObject { ["booleanValue"] = flag },
        int number => new JsonObject { ["integerValue"] = number.ToString(CultureInfo.InvariantCulture) },
        long number => new JsonObject { ["integerValue"] = number.ToString(CultureInfo.InvariantCulture) },
        double number => new JsonObject { ["doubleValue"] = number },
        DateTime date => new JsonObject
        {
            ["timestampValue"] = date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture),
        },
        IEnumerable<string> array => new JsonObject
        {
            ["arrayValue"] = new JsonObject
            {
                ["values"] = new JsonArray([.. array.Select(item => (JsonNode)EncodeValue(item))]),
            },
        },
        _ => throw new AppException($"Unsupported Firestore value type {value.GetType().Name}."),
    };

    private static FirestoreDocument DecodeDocument(JsonObject body)
    {
        var name = body["name"]?.GetValue<string>() ?? "";
        var id = name[(name.LastIndexOf('/') + 1)..];
        var fields = new Dictionary<string, object?>();
        if (body["fields"] is JsonObject encoded)
        {
            foreach (var (key, node) in encoded)
            {
                if (node is JsonObject value) fields[key] = DecodeValue(value);
            }
        }
        return new FirestoreDocument(id, fields);
    }

    private static object? DecodeValue(JsonObject value)
    {
        if (value.ContainsKey("stringValue")) return value["stringValue"]?.GetValue<string>();
        if (value.ContainsKey("booleanValue")) return value["booleanValue"]?.GetValue<bool>();
        if (value.ContainsKey("integerValue"))
        {
            return long.TryParse(value["integerValue"]?.GetValue<string>(), out var number) ? number : 0L;
        }
        if (value.ContainsKey("doubleValue")) return value["doubleValue"]?.GetValue<double>();
        if (value.ContainsKey("timestampValue"))
        {
            var raw = value["timestampValue"]?.GetValue<string>();
            return DateTime.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal, out var date)
                ? date
                : null;
        }
        if (value["arrayValue"] is JsonObject array && array["values"] is JsonArray values)
        {
            return values
                .OfType<JsonObject>()
                .Select(DecodeValue)
                .ToList();
        }
        return null;
    }
}
