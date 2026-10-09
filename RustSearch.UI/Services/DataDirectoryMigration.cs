using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace RustSearch.UI.Services;

public sealed record MigrationProgress(long CopiedBytes, long TotalBytes, int CopiedFiles, int TotalFiles, string CurrentFile);
public sealed record MigrationResult(string SourceDirectory, string DestinationDirectory, long TotalBytes, int FileCount);

/// <summary>
/// Copies a stopped backend's data to a new, empty directory.
/// The caller must stop the backend before copying and only change the persisted pointer after success.
/// </summary>
public static class DataDirectoryMigration
{
    private const int BufferSize = 1024 * 1024;
    private static readonly StringComparer PathComparer = StringComparer.OrdinalIgnoreCase;

    /// <summary>Read-only validation of directory locations, links, and destination contents.</summary>
    public static void Validate(string source, string destination)
    {
        _ = ValidateLocations(source, destination);
    }

    public static Task<MigrationResult> CopyAsync(string source, string destination,
        IProgress<MigrationProgress>? progress = null, CancellationToken ct = default) =>
        Task.Run(() => CopyCoreAsync(source, destination, progress, ct), ct);

    public static Task RemoveMigratedSourceAsync(string source, string destination) => Task.Run(() =>
    {
        source = Normalize(source);
        destination = Normalize(destination);
        if (PathComparer.Equals(source, destination) || IsUnder(source, destination) || IsUnder(destination, source))
            throw new IOException("迁移源目录与目标目录重叠，无法清理旧索引。");
        if (!File.Exists(Path.Combine(destination, "index", "meta.json")) ||
            !File.Exists(Path.Combine(destination, "meta.db")))
            throw new IOException("新目录的索引或数据库不存在，旧索引未清理。");

        var oldIndex = Path.Combine(source, "index");
        if (Directory.Exists(oldIndex))
        {
            EnsureNoLinks(oldIndex);
            if (!File.Exists(Path.Combine(oldIndex, "meta.json")) ||
                !File.Exists(Path.Combine(oldIndex, ".managed.json")))
                throw new IOException("旧目录中的 index 不是 RustSearch 索引，未删除。");
            Directory.Delete(oldIndex, recursive: true);
        }
        foreach (var name in new[] { "meta.db", "meta.db-wal", "meta.db-shm", "config.json",
                     "user_dict.txt", "ui-preferences.json", "ui-theme.txt", "winui-layout.json" })
        {
            var oldFile = Path.Combine(source, name);
            EnsureNoLinks(oldFile);
            if (File.Exists(oldFile)) File.Delete(oldFile);
        }
    });

    private static async Task<MigrationResult> CopyCoreAsync(string source, string destination,
        IProgress<MigrationProgress>? progress, CancellationToken ct)
    {
        var locations = ValidateLocations(source, destination);
        source = locations.Source;
        destination = locations.Destination;
        var manifest = ReadManifest(source, ct);
        var totalBytes = manifest.Files.Aggregate(0L, (total, file) => checked(total + file.Length));
        var parent = Path.GetDirectoryName(destination)!;
        var stage = Path.Combine(parent, ".rustsearch-migrate-" + Guid.NewGuid().ToString("N"));
        var ownedFiles = new List<string>();
        var ownedDirectories = new List<string>();
        var createdParents = new List<string>();
        var destinationRemoved = false;
        var copiedBytes = 0L;
        var copiedFiles = 0;
        var reportClock = Stopwatch.StartNew();

        void Report(string relativePath, bool force = false)
        {
            if (!force && reportClock.ElapsedMilliseconds < 150) return;
            progress?.Report(new(copiedBytes, totalBytes, copiedFiles, manifest.Files.Count, relativePath));
            reportClock.Restart();
        }

        try
        {
            ct.ThrowIfCancellationRequested();
            Report("正在检查迁移空间", true);
            CreateMissingParents(parent, createdParents);
            CheckAvailableSpace(parent, totalBytes);
            EnsureNoLinks(stage);
            if (Exists(stage)) throw new IOException("迁移临时目录已存在，请重试。");
            Directory.CreateDirectory(stage);
            ownedDirectories.Add(stage);

            foreach (var directory in manifest.Directories)
            {
                ct.ThrowIfCancellationRequested();
                var target = ChildPath(stage, directory.RelativePath);
                EnsureNoLinks(target);
                Directory.CreateDirectory(target);
                ownedDirectories.Add(target);
            }

            var buffer = new byte[BufferSize];
            foreach (var file in manifest.Files)
            {
                ct.ThrowIfCancellationRequested();
                var original = ChildPath(source, file.RelativePath);
                var target = ChildPath(stage, file.RelativePath);
                EnsureNoLinks(original);
                EnsureNoLinks(target);
                RequireUnchanged(original, file);
                // Keep the source open without write/delete sharing until the copied bytes are verified.
                await using (var input = new FileStream(original, FileMode.Open, FileAccess.Read,
                    FileShare.Read, BufferSize, FileOptions.Asynchronous | FileOptions.SequentialScan))
                {
                    byte[] expectedHash;
                    using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
                    {
                        await using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write,
                            FileShare.None, BufferSize, FileOptions.Asynchronous | FileOptions.SequentialScan))
                        {
                            ownedFiles.Add(target);
                            while (true)
                            {
                                var count = await input.ReadAsync(buffer.AsMemory(), ct).ConfigureAwait(false);
                                if (count == 0) break;
                                await output.WriteAsync(buffer.AsMemory(0, count), ct).ConfigureAwait(false);
                                hash.AppendData(buffer, 0, count);
                                copiedBytes += count;
                                Report(file.RelativePath);
                                ct.ThrowIfCancellationRequested();
                            }
                            await output.FlushAsync(ct).ConfigureAwait(false);
                            output.Flush(flushToDisk: true);
                        }
                        expectedHash = hash.GetHashAndReset();
                    }
                    await using var verification = new FileStream(target, FileMode.Open, FileAccess.Read,
                        FileShare.Read, BufferSize, FileOptions.Asynchronous | FileOptions.SequentialScan);
                    var actualHash = await SHA256.HashDataAsync(verification, ct).ConfigureAwait(false);
                    if (verification.Length != file.Length || !CryptographicOperations.FixedTimeEquals(expectedHash, actualHash))
                        throw new IOException($"迁移校验失败：{file.RelativePath}。原数据仍然保留。");
                    RequireUnchanged(original, file);
                }
                File.SetLastWriteTimeUtc(target, file.LastWriteUtc);
                File.SetAttributes(target, PortableAttributes(file.Attributes));
                copiedFiles++;
                Report(file.RelativePath, copiedFiles == 1 || copiedFiles == manifest.Files.Count);
                ct.ThrowIfCancellationRequested();
            }

            // Apply directory metadata after their children, since adding children changes directory mtime.
            foreach (var directory in manifest.Directories.AsEnumerable().Reverse())
            {
                var target = ChildPath(stage, directory.RelativePath);
                Directory.SetLastWriteTimeUtc(target, directory.LastWriteUtc);
                File.SetAttributes(target, PortableAttributes(directory.Attributes));
            }

            // A newly created or changed file means the backend/UI was not fully quiescent. Do not publish
            // a mixed snapshot. All source bytes, including SQLite journals, remain untouched.
            var current = ReadManifest(source, ct);
            if (!SameManifest(manifest, current))
                throw new IOException("迁移期间原数据发生了变化，请暂停其他操作后重试。原数据仍然保留。");
            Report("校验完成，正在切换目录", true);
            ct.ThrowIfCancellationRequested();

            // Revalidate immediately before publishing. Directory.Move never overwrites an existing path.
            // Removing an already empty destination uses non-recursive deletion, so concurrent new files
            // cause an error instead of being deleted.
            var finalLocations = ValidateLocations(source, destination);
            if (!PathComparer.Equals(finalLocations.Source, source) || !PathComparer.Equals(finalLocations.Destination, destination))
                throw new IOException("迁移期间目录位置发生了变化，请重试。");
            EnsureNoLinks(stage);
            if (Directory.Exists(destination))
            {
                Directory.Delete(destination, recursive: false);
                destinationRemoved = true;
            }
            Directory.Move(stage, destination);
            return new(source, destination, totalBytes, copiedFiles);
        }
        catch (Exception error)
        {
            // Delete only paths this operation created. Never recursively delete the user's destination.
            var cleanupErrors = CleanupOwned(ownedFiles, ownedDirectories, createdParents);
            if (destinationRemoved && !Exists(destination))
            {
                try { EnsureNoLinks(destination); Directory.CreateDirectory(destination); }
                catch (Exception restoreError) when (IsFileSystemError(restoreError)) { cleanupErrors.Add(restoreError.Message); }
            }
            if (cleanupErrors.Count > 0)
                throw new IOException($"迁移未完成，原数据仍然保留。临时文件无法完全清理，请检查 {stage}。原因：{error.Message}", error);
            throw;
        }
    }

    private static (string Source, string Destination) ValidateLocations(string source, string destination)
    {
        source = Normalize(source);
        destination = Normalize(destination);
        if (!Directory.Exists(source)) throw new DirectoryNotFoundException("原数据文件夹不存在，无法迁移。");
        if (PathComparer.Equals(source, destination)) throw new IOException("请选择与当前数据文件夹不同的位置。");
        if (IsUnder(source, destination) || IsUnder(destination, source))
            throw new IOException("原数据文件夹与新文件夹不能互相包含，请选择独立的新文件夹。");
        if (Path.GetDirectoryName(destination) is null)
            throw new IOException("不能将磁盘根目录直接作为迁移目标，请创建一个专用空文件夹。");
        if (File.Exists(destination)) throw new IOException("目标路径是文件，请选择一个空文件夹。");
        if (Directory.Exists(destination) && Directory.EnumerateFileSystemEntries(destination).Any())
            throw new IOException("目标文件夹不是空的。为避免覆盖已有数据，请选择一个新的空文件夹。");
        return (source, destination);
    }

    private static string Normalize(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) throw new ArgumentException("数据文件夹路径不能为空。");
        path = path.Trim();
        if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) path = @"\\" + path[8..];
        else if (path.StartsWith(@"\\?\", StringComparison.Ordinal) && path.Length > 6 && path[5] == ':') path = path[4..];
        else if (path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\\.\", StringComparison.Ordinal))
            throw new IOException("不支持设备路径，请选择普通磁盘文件夹。");
        path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        if (OperatingSystem.IsWindows() && path.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                .Any(segment => segment.EndsWith(' ') || segment.EndsWith('.')))
            throw new IOException("文件夹名称不能以空格或句点结尾。");
        EnsureNoLinks(path);

        // Expand existing DOS 8.3 aliases before comparing paths (ADMINI~1 and Administrator must not
        // evade the same/nested-directory checks). Nonexistent suffixes are appended after expansion.
        if (OperatingSystem.IsWindows())
        {
            var existing = path;
            var suffix = new Stack<string>();
            while (!Exists(existing))
            {
                suffix.Push(Path.GetFileName(existing));
                existing = Path.GetDirectoryName(existing) ?? throw new DirectoryNotFoundException("目标磁盘或共享目录不存在。");
            }
            var expanded = new StringBuilder(32768);
            var length = GetLongPathName(existing, expanded, (uint)expanded.Capacity);
            if (length == 0 || length >= expanded.Capacity)
                throw new IOException("无法解析数据文件夹的实际路径。", new Win32Exception(Marshal.GetLastWin32Error()));
            path = expanded.ToString();
            while (suffix.Count > 0) path = Path.Combine(path, suffix.Pop());
            path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
            EnsureNoLinks(path);
        }
        return path;
    }

    private static bool IsUnder(string path, string parent) => path.StartsWith(
        Path.EndsInDirectorySeparator(parent) ? parent : parent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);

    private static string ChildPath(string root, string relative)
    {
        var path = Path.GetFullPath(Path.Combine(root, relative));
        if (!IsUnder(path, root)) throw new IOException("数据目录中包含无效的相对路径。");
        return path;
    }

    private static bool Exists(string path)
    {
        try { _ = File.GetAttributes(path); return true; }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }

    private static void EnsureNoLinks(string path)
    {
        for (string? current = path; current is not null; current = Path.GetDirectoryName(current))
        {
            try
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException($"迁移暂不支持符号链接、目录联接或其他重解析点：{current}");
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }

    private static Manifest ReadManifest(string source, CancellationToken ct)
    {
        var result = new Manifest(new(), new());
        var pending = new Stack<string>();
        pending.Push(source);
        while (pending.Count > 0)
        {
            ct.ThrowIfCancellationRequested();
            var directory = pending.Pop();
            EnsureNoLinks(directory);
            foreach (var path in Directory.EnumerateFileSystemEntries(directory).OrderBy(p => p, PathComparer))
            {
                ct.ThrowIfCancellationRequested();
                var name = Path.GetFileName(path);
                // This pointer belongs to the stable settings location, and live diagnostic logs are
                // unrelated to index state. All other files (including hidden files/journals) are copied.
                if (PathComparer.Equals(directory, source) &&
                    (PathComparer.Equals(name, "ui-settings.json") || PathComparer.Equals(name, "logs"))) continue;
                EnsureNoLinks(path);
                var attributes = File.GetAttributes(path);
                var relative = Path.GetRelativePath(source, path);
                if ((attributes & FileAttributes.Directory) != 0)
                {
                    result.Directories.Add(new(relative, Directory.GetLastWriteTimeUtc(path), attributes));
                    pending.Push(path);
                }
                else
                {
                    var info = new FileInfo(path);
                    result.Files.Add(new(relative, info.Length, info.LastWriteTimeUtc, attributes));
                }
            }
        }
        // Parents always precede their children, independently of enumeration order.
        result.Directories.Sort((a, b) => a.RelativePath.Length.CompareTo(b.RelativePath.Length));
        result.Files.Sort((a, b) => PathComparer.Compare(a.RelativePath, b.RelativePath));
        return result;
    }

    private static bool SameManifest(Manifest a, Manifest b) =>
        a.Files.SequenceEqual(b.Files) && a.Directories.Select(d => d.RelativePath).OrderBy(p => p, PathComparer)
            .SequenceEqual(b.Directories.Select(d => d.RelativePath).OrderBy(p => p, PathComparer), PathComparer);

    private static void RequireUnchanged(string path, FileEntry file)
    {
        var current = new FileInfo(path);
        if (current.Length != file.Length || current.LastWriteTimeUtc != file.LastWriteUtc)
            throw new IOException($"迁移期间文件发生了变化：{file.RelativePath}。请暂停其他操作后重试。");
    }

    private static FileAttributes PortableAttributes(FileAttributes attributes)
    {
        var selected = attributes & (FileAttributes.ReadOnly | FileAttributes.Hidden | FileAttributes.System | FileAttributes.Archive);
        return selected != 0 ? selected : FileAttributes.Normal;
    }

    private static void CreateMissingParents(string parent, List<string> created)
    {
        var missing = new Stack<string>();
        for (string? path = parent; path is not null && !Directory.Exists(path); path = Path.GetDirectoryName(path))
            missing.Push(path);
        while (missing.Count > 0)
        {
            var path = missing.Pop();
            EnsureNoLinks(path);
            if (Exists(path)) throw new IOException("目标父目录已被其他文件占用。");
            Directory.CreateDirectory(path);
            created.Add(path);
        }
    }

    private static void CheckAvailableSpace(string destinationParent, long bytes)
    {
        long? freeBytes = null;
        try { freeBytes = new DriveInfo(Path.GetPathRoot(destinationParent)!).AvailableFreeSpace; }
        catch (IOException) { } // Some network shares do not expose available space; writes still fail safely.
        catch (ArgumentException) { }
        catch (UnauthorizedAccessException) { }
        if (freeBytes is { } available && available < bytes)
            throw new IOException($"目标磁盘空间不足，需要约 {Math.Ceiling(bytes / 1048576d):N0} MB，可用 {Math.Floor(available / 1048576d):N0} MB。");
    }

    private static List<string> CleanupOwned(List<string> files, List<string> directories, List<string> parents)
    {
        var errors = new List<string>();
        foreach (var file in files.AsEnumerable().Reverse())
        {
            try
            {
                EnsureNoLinks(file);
                if (!Exists(file)) continue;
                File.SetAttributes(file, File.GetAttributes(file) & ~FileAttributes.ReadOnly);
                File.Delete(file);
            }
            catch (Exception error) when (IsFileSystemError(error)) { errors.Add(error.Message); }
        }
        // Directory list must be deepest-first for non-recursive cleanup.
        foreach (var directory in directories.AsEnumerable().Reverse().Concat(parents.AsEnumerable().Reverse()))
        {
            try
            {
                EnsureNoLinks(directory);
                if (!Directory.Exists(directory)) continue;
                File.SetAttributes(directory, File.GetAttributes(directory) & ~FileAttributes.ReadOnly);
                Directory.Delete(directory, recursive: false);
            }
            catch (Exception error) when (IsFileSystemError(error)) { errors.Add(error.Message); }
        }
        return errors;
    }

    private static bool IsFileSystemError(Exception error) => error is IOException or UnauthorizedAccessException;
    private sealed record FileEntry(string RelativePath, long Length, DateTime LastWriteUtc, FileAttributes Attributes);
    private sealed record DirectoryEntry(string RelativePath, DateTime LastWriteUtc, FileAttributes Attributes);
    private sealed record Manifest(List<DirectoryEntry> Directories, List<FileEntry> Files);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "GetLongPathNameW")]
    private static extern uint GetLongPathName(string shortPath, StringBuilder longPath, uint bufferLength);
}
