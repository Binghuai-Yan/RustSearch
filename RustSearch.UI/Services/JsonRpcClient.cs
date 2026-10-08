using System.Collections.Concurrent;
using System.Text.Json;

namespace RustSearch.UI.Services;

public sealed class JsonRpcClient : IDisposable
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true
    };
    private readonly BackendProcess _backend;
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonElement>> _pending = new();
    private long _nextId;
    public event Action<string, JsonElement>? OnEvent;

    public JsonRpcClient(BackendProcess backend)
    {
        _backend = backend;
        _backend.LineReceived += HandleLine;
        _backend.Disconnected += FailPending;
    }

    public async Task<T> CallAsync<T>(string method, object? param = null,
        CancellationToken ct = default, int timeoutMs = 30000)
    {
        var id = Interlocked.Increment(ref _nextId);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = completion;
        using var timeout = new CancellationTokenSource(timeoutMs);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, timeout.Token);
        using var registration = linked.Token.Register(() => completion.TrySetCanceled(linked.Token));
        try
        {
            await _backend.SendAsync(JsonSerializer.Serialize(new { id, method, @params = param ?? new { } }, JsonOptions), linked.Token).WaitAsync(linked.Token);
            var element = await completion.Task;
            return element.Deserialize<T>(JsonOptions) ?? throw new IOException("后端返回了空响应。");
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested && !ct.IsCancellationRequested)
        {
            throw new TimeoutException("本地引擎响应超时，请稍后重试。");
        }
        finally { _pending.TryRemove(id, out _); }
    }

    private void HandleLine(string line)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (root.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.Number && id.TryGetInt64(out var requestId))
            {
                if (!_pending.TryRemove(requestId, out var completion)) return;
                if (root.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.True)
                    completion.TrySetResult(root.GetProperty("result").Clone());
                else
                {
                    var error = root.GetProperty("error");
                    completion.TrySetException(new BackendException(error.GetProperty("code").GetString() ?? "INTERNAL_ERROR",
                        error.GetProperty("message").GetString() ?? "未知错误"));
                }
            }
            else if (root.TryGetProperty("event", out var eventName) && root.TryGetProperty("data", out var data))
                OnEvent?.Invoke(eventName.GetString() ?? "", data.Clone());
        }
        catch (JsonException) { }
        catch (InvalidOperationException) { }
        catch (KeyNotFoundException) { }
    }

    private void FailPending()
    {
        foreach (var entry in _pending)
            if (_pending.TryRemove(entry.Key, out var completion))
                completion.TrySetException(new IOException("本地引擎连接已中断，正在尝试重新连接。"));
    }

    public void Dispose()
    {
        _backend.LineReceived -= HandleLine;
        _backend.Disconnected -= FailPending;
        FailPending();
    }
}
