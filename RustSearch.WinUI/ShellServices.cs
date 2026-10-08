using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using Microsoft.UI.Xaml;
using Forms = System.Windows.Forms;

namespace RustSearch.WinUI;

public sealed class TrayService : IDisposable
{
    private readonly Forms.NotifyIcon _notifyIcon;
    private readonly Forms.ContextMenuStrip _menu;
    private readonly System.Drawing.Icon _icon;
    private bool _disposed;

    public TrayService(Window owner, Action show, Action settings, Action exit)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(show);
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(exit);

        void Dispatch(Action action) => owner.DispatcherQueue.TryEnqueue(() => action());

        var path = Path.Combine(AppContext.BaseDirectory, "Assets", "RustSearch.ico");
        _icon = File.Exists(path)
            ? new System.Drawing.Icon(path)
            : (System.Drawing.Icon)System.Drawing.SystemIcons.Application.Clone();
        _menu = new Forms.ContextMenuStrip();
        _menu.Items.Add("显示 RustSearch", null, (_, _) => Dispatch(show));
        _menu.Items.Add("设置", null, (_, _) => Dispatch(settings));
        _menu.Items.Add(new Forms.ToolStripSeparator());
        _menu.Items.Add("退出", null, (_, _) => Dispatch(exit));
        _notifyIcon = new Forms.NotifyIcon
        {
            Icon = _icon,
            Text = "RustSearch",
            ContextMenuStrip = _menu,
            Visible = true
        };
        _notifyIcon.DoubleClick += (_, _) => Dispatch(show);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _menu.Dispose();
        _icon.Dispose();
    }
}

public sealed class InstanceService : IDisposable
{
    private readonly Mutex _mutex;
    private readonly EventWaitHandle _show;
    private readonly EventWaitHandle _exit;
    private readonly ManualResetEvent _stop = new(false);
    private Thread? _listener;
    private bool _ownsMutex;
    private bool _attempted;
    private bool _disposed;

    public InstanceService(string dataDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(dataDirectory);
        var canonicalDirectory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(dataDirectory))
            .ToUpperInvariant();
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonicalDirectory)));
        var name = @"Local\RustSearch.WinUI." + hash;
        _mutex = new Mutex(false, name + ".Instance");
        // Create the signals before acquiring the mutex so a rapid second launch cannot lose activation.
        _show = new EventWaitHandle(false, EventResetMode.AutoReset, name + ".Show");
        _exit = new EventWaitHandle(false, EventResetMode.AutoReset, name + ".Exit");
    }

    public bool TryAcquire(bool exitRequested, Action show, Action exit)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(show);
        ArgumentNullException.ThrowIfNull(exit);
        if (_attempted) throw new InvalidOperationException("Instance acquisition may only be attempted once.");
        _attempted = true;
        try { _ownsMutex = _mutex.WaitOne(0); }
        catch (AbandonedMutexException) { _ownsMutex = true; }

        if (!_ownsMutex)
        {
            (exitRequested ? _exit : _show).Set();
            return false;
        }
        if (exitRequested)
        {
            _mutex.ReleaseMutex();
            _ownsMutex = false;
            return false;
        }

        _listener = new Thread(() => Listen(show, exit))
        {
            IsBackground = true,
            Name = "RustSearch instance activation"
        };
        _listener.Start();
        return true;
    }

    private void Listen(Action show, Action exit)
    {
        WaitHandle[] signals = [_stop, _exit, _show];
        while (true)
        {
            var signal = WaitHandle.WaitAny(signals);
            if (signal == 0) return;
            try { (signal == 1 ? exit : show)(); }
            catch (Exception exception) { Trace.TraceError("Instance activation failed: {0}", exception); }
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _stop.Set();
        if (_listener is not null && _listener != Thread.CurrentThread) _listener.Join();
        if (_ownsMutex)
        {
            // Mutex ownership belongs to the thread that calls TryAcquire; dispose on that same UI thread.
            _mutex.ReleaseMutex();
            _ownsMutex = false;
        }
        _show.Dispose();
        _exit.Dispose();
        _stop.Dispose();
        _mutex.Dispose();
    }
}

public static class WindowShell
{
    public static void Show(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(window);
        ShowWindow(handle, IsIconic(handle) ? 9 : 5);
        window.Activate();
        SetForegroundWindow(handle);
    }

    public static void Hide(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        ShowWindow(WinRT.Interop.WindowNative.GetWindowHandle(window), 0);
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(nint window, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(nint window);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint window);
}
