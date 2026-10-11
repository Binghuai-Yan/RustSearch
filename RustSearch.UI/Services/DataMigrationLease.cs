namespace RustSearch.UI.Services;

/// <summary>Prevents a new shared engine from opening the source during migration.</summary>
public sealed class DataMigrationLease : IDisposable
{
    private readonly FileStream _stream;
    public DataMigrationLease(string directory)
    {
        _stream = new FileStream(Path.Combine(directory, ".migration.lock"), FileMode.OpenOrCreate,
            FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose);
    }
    public void Dispose() => _stream.Dispose();
}
