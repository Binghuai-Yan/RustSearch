using System.Text;
using System.Text.Json;
using RustSearch.UI.Services;

// Private, piped helper: reuse the native frontends' verified migration code.
// The caller disconnects its bridge before launching us, and reconnects only
// after the final result. Closing stdin cancels and rolls back the transaction.
Console.InputEncoding = new UTF8Encoding(false);
Console.OutputEncoding = new UTF8Encoding(false);
var outputGate = new object();
void Emit(object value) { lock (outputGate) Console.WriteLine(JsonSerializer.Serialize(value)); }
using var cancellation = new CancellationTokenSource();
using var backend = new BackendProcess();
using var rpc = new JsonRpcClient(backend);
var previous = AppPaths.DataDirectory;
var switched = false;
var copied = false;
try
{
    var line = await Console.In.ReadLineAsync() ?? throw new IOException("缺少迁移请求。");
    using var request = JsonDocument.Parse(line);
    var destination = Path.GetFullPath(request.RootElement.GetProperty("destination").GetString()!);
    var migrate = request.RootElement.GetProperty("migrate").GetBoolean();
    if (migrate) DataDirectoryMigration.Validate(previous, destination);
    if (string.Equals(Path.TrimEndingDirectorySeparator(previous), Path.TrimEndingDirectorySeparator(destination), StringComparison.OrdinalIgnoreCase))
        throw new IOException("请选择不同的数据目录。");
    _ = Task.Run(async () => { await Console.In.ReadLineAsync(); cancellation.Cancel(); });
    await backend.StartAsync();
    await rpc.CallAsync<JsonElement>("app.stats", ct: cancellation.Token);
    // Must remain alive through rollback and source cleanup, not just copying.
    using var lease = new DataMigrationLease(previous);
    try
    {
        await rpc.CallAsync<JsonElement>("app.prepare_migration", ct: cancellation.Token);
        await backend.StopAsync();
        if (migrate)
        {
            await DataDirectoryMigration.CopyAsync(previous, destination,
                new InlineProgress(p => Emit(new { progress = p })), cancellation.Token);
            copied = true;
        }
        cancellation.Token.ThrowIfCancellationRequested();
        AppPaths.SetDataDirectory(destination);
        switched = true;
        await backend.ReconnectAsync();
        // Do not remove any source data until the new engine actually responds.
        await rpc.CallAsync<JsonElement>("app.stats", ct: cancellation.Token);
        await rpc.CallAsync<JsonElement>("config.get", ct: cancellation.Token);
        cancellation.Token.ThrowIfCancellationRequested();
        string? warning = null;
        if (migrate)
        {
            try { await DataDirectoryMigration.RemoveMigratedSourceAsync(previous, destination); }
            catch (Exception e) { warning = "迁移完成，原目录部分数据未清理：" + e.Message; }
        }
        Emit(new { ok = true, data_directory = destination, warning });
    }
    catch
    {
        await backend.StopAsync();
        if (switched) AppPaths.SetDataDirectory(previous);
        // Release the source lease before asking a new source broker to start.
        lease.Dispose();
        await backend.ReconnectAsync();
        await rpc.CallAsync<JsonElement>("app.stats");
        throw;
    }
}
catch (Exception e)
{
    Emit(new { ok = false, data_directory = AppPaths.DataDirectory,
        error = (e is OperationCanceledException ? "迁移已取消。" : e.Message) +
            (copied ? " 新目录中的完整副本已保留。" : " 原数据仍保留。") });
    Environment.ExitCode = 1;
}
finally { await backend.StopAsync(); }

sealed class InlineProgress(Action<MigrationProgress> report) : IProgress<MigrationProgress>
{
    public void Report(MigrationProgress value) => report(value);
}
