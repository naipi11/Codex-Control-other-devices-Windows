using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Text;

internal struct Point
{
    internal int X;
    internal int Y;
    internal Point(int x, int y) { X = x; Y = y; }
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct NotifyIconData
{
    internal uint cbSize;
    internal IntPtr hWnd;
    internal uint uID;
    internal uint uFlags;
    internal uint uCallbackMessage;
    internal IntPtr hIcon;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string szTip;
    internal uint dwState;
    internal uint dwStateMask;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] internal string szInfo;
    internal uint uTimeoutOrVersion;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] internal string szInfoTitle;
    internal uint dwInfoFlags;
    internal Guid guidItem;
    internal IntPtr hBalloonIcon;
}

internal interface ISpikeNative
{
    IntPtr CreatePersistentOwner();
    IntPtr ImmAssociateContext(IntPtr hwnd, IntPtr himc);
    IntPtr ImmGetContext(IntPtr hwnd);
    bool ImmReleaseContext(IntPtr hwnd, IntPtr himc);
    bool SetForegroundWindow(IntPtr hwnd);
    IntPtr GetForegroundWindow();
    IntPtr CreatePopupMenu();
    bool AppendMenu(IntPtr menu, uint flags, UIntPtr commandId, string text);
    bool AppendSubMenu(IntPtr menu, IntPtr childMenu, string text);
    uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters);
    bool PostMessage(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);
    bool ShellNotifyIcon(uint message, ref NotifyIconData data);
    bool DestroyMenu(IntPtr menu);
    bool DestroyWindow(IntPtr hwnd);
}

internal sealed class SpikeSnapshot
{
    internal bool OwnerHasNoInputContext;
    internal int MenuAttempts;
    internal int TrackCalls;
    internal int ForegroundFailures;
    internal long TrackMinMilliseconds = long.MaxValue;
    internal long TrackMaxMilliseconds;
    internal long TrackTotalMilliseconds;
    internal int CancelCount;
    internal int SelectedCount;
}

internal sealed class NoHimcSpikeController : IDisposable
{
    private const uint NimAdd = 0;
    private const uint NimModify = 1;
    private const uint NimDelete = 2;
    private const uint NimSetFocus = 3;
    private const uint NimSetVersion = 4;
    private const uint NifMessage = 1;
    private const uint NifIcon = 2;
    private const uint NifTip = 4;
    private const uint MfString = 0;
    private const uint MfGrayed = 1;
    private const uint MfPopup = 0x10;
    private const uint TpmReturnCmd = 0x100;
    private const uint TpmRightButton = 2;
    private const uint TpmNoNotify = 0x80;
    private const uint WmNull = 0;

    private readonly ISpikeNative _native;
    private IntPtr _owner;
    private IntPtr _savedDefaultHimc;
    private NotifyIconData _iconData;
    private bool _initialized;
    private bool _menuOpen;
    private readonly SpikeSnapshot _snapshot = new SpikeSnapshot();

    internal NoHimcSpikeController(ISpikeNative native)
    {
        if (native == null) { throw new ArgumentNullException("native"); }
        _native = native;
    }

    internal SpikeSnapshot Snapshot { get { return _snapshot; } }

    public void Initialize()
    {
        if (_initialized) { return; }
        _owner = _native.CreatePersistentOwner();
        if (_owner == IntPtr.Zero) { throw new InvalidOperationException("owner creation failed"); }
        try
        {
            _savedDefaultHimc = _native.ImmAssociateContext(_owner, IntPtr.Zero);
            IntPtr current = _native.ImmGetContext(_owner);
            if (current != IntPtr.Zero)
            {
                try { _native.ImmReleaseContext(_owner, current); }
                finally { throw new InvalidOperationException("owner has an input context"); }
            }
            _snapshot.OwnerHasNoInputContext = true;
            _iconData = new NotifyIconData
            {
                cbSize = (uint)Marshal.SizeOf(typeof(NotifyIconData)),
                hWnd = _owner,
                uID = 1,
                uFlags = NifMessage | NifIcon | NifTip,
                uCallbackMessage = Win32SpikeNative.CallbackMessage,
                hIcon = Win32SpikeNative.ApplicationIcon,
                szTip = "TEST ONLY - no-HIMC spike"
            };
            if (!_native.ShellNotifyIcon(NimAdd, ref _iconData)) { throw new InvalidOperationException("NIM_ADD failed"); }
            _iconData.uTimeoutOrVersion = 4;
            if (!_native.ShellNotifyIcon(NimSetVersion, ref _iconData)) { throw new InvalidOperationException("NIM_SETVERSION failed"); }
            _initialized = true;
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    internal uint ShowMenu(Point point)
    {
        if (!_initialized || _menuOpen) { return 0; }
        _menuOpen = true;
        _snapshot.MenuAttempts++;
        IntPtr menu = IntPtr.Zero;
        try
        {
            menu = _native.CreatePopupMenu();
            if (menu == IntPtr.Zero) { throw new InvalidOperationException("CreatePopupMenu failed"); }
            AppendDisabled(menu, "Spike title");
            IntPtr language = _native.CreatePopupMenu();
            if (language == IntPtr.Zero) { throw new InvalidOperationException("language menu creation failed"); }
            AppendEnabled(language, 1, "Chinese");
            AppendEnabled(language, 2, "English");
            if (!_native.AppendSubMenu(menu, language, "Language")) { throw new InvalidOperationException("language submenu failed"); }
            AppendEnabled(menu, 3, "No-op");

            if (!_native.SetForegroundWindow(_owner) || _native.GetForegroundWindow() != _owner)
            {
                _snapshot.ForegroundFailures++;
                return 0;
            }
            _snapshot.TrackCalls++;
            long trackStarted = Stopwatch.GetTimestamp();
            uint command = _native.TrackPopupMenuEx(menu, TpmReturnCmd | TpmRightButton | TpmNoNotify, point.X, point.Y, _owner, IntPtr.Zero);
            long elapsedMilliseconds = (Stopwatch.GetTimestamp() - trackStarted) * 1000L / Stopwatch.Frequency;
            if (elapsedMilliseconds < _snapshot.TrackMinMilliseconds) { _snapshot.TrackMinMilliseconds = elapsedMilliseconds; }
            if (elapsedMilliseconds > _snapshot.TrackMaxMilliseconds) { _snapshot.TrackMaxMilliseconds = elapsedMilliseconds; }
            _snapshot.TrackTotalMilliseconds += elapsedMilliseconds;
            if (command == 0) { _snapshot.CancelCount++; } else { _snapshot.SelectedCount++; }
            if (!_native.PostMessage(_owner, WmNull, UIntPtr.Zero, IntPtr.Zero)) { throw new InvalidOperationException("WM_NULL failed"); }
            if (!_native.ShellNotifyIcon(NimSetFocus, ref _iconData)) { throw new InvalidOperationException("NIM_SETFOCUS failed"); }
            return command;
        }
        finally
        {
            if (menu != IntPtr.Zero) { _native.DestroyMenu(menu); }
            _menuOpen = false;
        }
    }

    private void AppendDisabled(IntPtr menu, string text)
    {
        if (!_native.AppendMenu(menu, MfString | MfGrayed, UIntPtr.Zero, text)) { throw new InvalidOperationException("menu item failed"); }
    }

    private void AppendEnabled(IntPtr menu, uint command, string text)
    {
        if (!_native.AppendMenu(menu, MfString, new UIntPtr(command), text)) { throw new InvalidOperationException("menu item failed"); }
    }

    internal SpikeSnapshot GetSnapshot() { return _snapshot; }

    public void Dispose()
    {
        if (_owner == IntPtr.Zero) { return; }
        try
        {
            _native.ImmAssociateContext(_owner, _savedDefaultHimc);
            if (_initialized) { _native.ShellNotifyIcon(NimDelete, ref _iconData); }
        }
        finally
        {
            _native.DestroyWindow(_owner);
            _owner = IntPtr.Zero;
            _initialized = false;
        }
    }
}

internal sealed class Win32SpikeNative : ISpikeNative
{
    internal const uint CallbackMessage = 0x8001;
    internal static IntPtr ApplicationIcon;
    internal Action<Point> ContextMenuCallback;
    private static readonly NativeWindowProc WindowProc = WindowProcedure;
    private static Win32SpikeNative _current;
    private IntPtr _owner;
    private ushort _classAtom;
    private uint _threadId;

    public IntPtr CreatePersistentOwner()
    {
        _current = this;
        _threadId = GetCurrentThreadId();
        ApplicationIcon = NativeLoadIcon(IntPtr.Zero, new IntPtr(32515));
        if (ApplicationIcon == IntPtr.Zero) { throw new InvalidOperationException("LoadIcon failed"); }
        WNDCLASS windowClass = new WNDCLASS
        {
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(WindowProc),
            hInstance = GetModuleHandle(null),
            lpszClassName = "CodexRemoteNoHimcSpikeV1"
        };
        _classAtom = RegisterClass(ref windowClass);
        if (_classAtom == 0 && GetLastError() != 1410) { throw new InvalidOperationException("RegisterClass failed"); }
        _owner = CreateWindowEx(0x80, windowClass.lpszClassName, "CodexRemoteNoHimcSpikeV1", 0x80000000, -32000, -32000, 1, 1, IntPtr.Zero, IntPtr.Zero, windowClass.hInstance, IntPtr.Zero);
        if (_owner == IntPtr.Zero) { throw new InvalidOperationException("CreateWindowEx failed"); }
        return _owner;
    }

    public IntPtr ImmAssociateContext(IntPtr hwnd, IntPtr himc) { return NativeImmAssociateContext(hwnd, himc); }
    public IntPtr ImmGetContext(IntPtr hwnd) { return NativeImmGetContext(hwnd); }
    public bool ImmReleaseContext(IntPtr hwnd, IntPtr himc) { return NativeImmReleaseContext(hwnd, himc); }
    public bool SetForegroundWindow(IntPtr hwnd) { return NativeSetForegroundWindow(hwnd); }
    public IntPtr GetForegroundWindow() { return NativeGetForegroundWindow(); }
    public IntPtr CreatePopupMenu() { return NativeCreatePopupMenu(); }
    public bool AppendMenu(IntPtr menu, uint flags, UIntPtr commandId, string text) { return NativeAppendMenu(menu, flags, commandId, text); }
    public bool AppendSubMenu(IntPtr menu, IntPtr childMenu, string text) { return NativeAppendMenu(menu, MfPopup, ToUIntPtr(childMenu), text); }
    public uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters) { return NativeTrackPopupMenuEx(menu, flags, x, y, owner, parameters); }
    public bool PostMessage(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam) { return NativePostMessage(hwnd, message, wParam, lParam); }
    public bool ShellNotifyIcon(uint message, ref NotifyIconData data) { return NativeShellNotifyIcon(message, ref data); }
    public bool DestroyMenu(IntPtr menu) { return NativeDestroyMenu(menu); }
    public bool DestroyWindow(IntPtr hwnd) { return NativeDestroyWindow(hwnd); }

    internal void RunMessageLoop()
    {
        MSG message;
        while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref message);
            DispatchMessage(ref message);
        }
    }

    internal void Stop() { PostQuitMessage(0); }

    private static IntPtr WindowProcedure(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam)
    {
        if (message == CallbackMessage)
        {
            uint eventCode = unchecked((uint)lParam.ToInt64()) & 0xffffu;
            if (eventCode == 0x007b && _current != null && _current.ContextMenuCallback != null)
            {
                POINT point;
                GetCursorPos(out point);
                _current.ContextMenuCallback(new Point(point.X, point.Y));
            }
            return IntPtr.Zero;
        }
        return DefWindowProc(hwnd, message, wParam, lParam);
    }

    private static UIntPtr ToUIntPtr(IntPtr value) { return new UIntPtr(unchecked((ulong)value.ToInt64())); }
    private delegate IntPtr NativeWindowProc(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct WNDCLASS { public uint style; public IntPtr lpfnWndProc; public int cbClsExtra; public int cbWndExtra; public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground; public string lpszMenuName; public string lpszClassName; }
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] private struct MSG { public IntPtr hwnd; public uint message; public UIntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; }
    private const uint MfPopup = 0x10;

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern ushort RegisterClass(ref WNDCLASS windowClass);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateWindowEx(uint exStyle, string className, string windowName, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")] private static extern IntPtr DefWindowProc(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern int GetMessage(out MSG message, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG message);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG message);
    [DllImport("user32.dll")] private static extern void PostQuitMessage(int exitCode);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string name);
    [DllImport("kernel32.dll")] private static extern uint GetLastError();
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll", EntryPoint = "DestroyWindow")] private static extern bool NativeDestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll", EntryPoint = "LoadIconW")] private static extern IntPtr NativeLoadIcon(IntPtr instance, IntPtr iconName);
    [DllImport("imm32.dll", EntryPoint = "ImmAssociateContext")] private static extern IntPtr NativeImmAssociateContext(IntPtr hwnd, IntPtr himc);
    [DllImport("imm32.dll", EntryPoint = "ImmGetContext")] private static extern IntPtr NativeImmGetContext(IntPtr hwnd);
    [DllImport("imm32.dll", EntryPoint = "ImmReleaseContext")] private static extern bool NativeImmReleaseContext(IntPtr hwnd, IntPtr himc);
    [DllImport("user32.dll", EntryPoint = "SetForegroundWindow")] private static extern bool NativeSetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll", EntryPoint = "GetForegroundWindow")] private static extern IntPtr NativeGetForegroundWindow();
    [DllImport("user32.dll", EntryPoint = "CreatePopupMenu")] private static extern IntPtr NativeCreatePopupMenu();
    [DllImport("user32.dll", EntryPoint = "AppendMenuW", CharSet = CharSet.Unicode)] private static extern bool NativeAppendMenu(IntPtr menu, uint flags, UIntPtr commandId, string text);
    [DllImport("user32.dll", EntryPoint = "TrackPopupMenuEx")] private static extern uint NativeTrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters);
    [DllImport("user32.dll", EntryPoint = "PostMessageW")] private static extern bool NativePostMessage(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam);
    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)] private static extern bool NativeShellNotifyIcon(uint message, ref NotifyIconData data);
    [DllImport("user32.dll", EntryPoint = "DestroyMenu")] private static extern bool NativeDestroyMenu(IntPtr menu);
}

internal static class NoHimcSpikeProgram
{
    public static int Main(string[] args)
    {
        if (args.Length < 1 || !String.Equals(args[0], "--manual", StringComparison.Ordinal) || args.Length < 3)
        {
            return 2;
        }
        int trials;
        if (!Int32.TryParse(args[1], out trials) || trials < 1 || trials > 100) { return 2; }
        string reportPath = Path.GetFullPath(args[2]);
        Win32SpikeNative native = new Win32SpikeNative();
        NoHimcSpikeController controller = new NoHimcSpikeController(native);
        int attempts = 0;
        try
        {
            controller.Initialize();
            native.ContextMenuCallback = delegate(Point point)
            {
                attempts++;
                controller.ShowMenu(point);
                if (attempts >= trials) { native.Stop(); }
            };
            native.RunMessageLoop();
            SpikeSnapshot snapshot = controller.GetSnapshot();
            long minMilliseconds = snapshot.TrackCalls == 0 ? 0 : snapshot.TrackMinMilliseconds;
            long averageMilliseconds = snapshot.TrackCalls == 0 ? 0 : snapshot.TrackTotalMilliseconds / snapshot.TrackCalls;
            File.WriteAllText(reportPath, "{\"attempts\":" + attempts + ",\"trackCalls\":" + snapshot.TrackCalls + ",\"trackMinMs\":" + minMilliseconds + ",\"trackMaxMs\":" + snapshot.TrackMaxMilliseconds + ",\"trackAverageMs\":" + averageMilliseconds + ",\"cancelCount\":" + snapshot.CancelCount + ",\"selectedCount\":" + snapshot.SelectedCount + ",\"foregroundFailures\":" + snapshot.ForegroundFailures + ",\"ownerHasNoInputContext\":" + (snapshot.OwnerHasNoInputContext ? "true" : "false") + "}", Encoding.UTF8);
            return attempts == trials ? 0 : 1;
        }
        catch (Exception error)
        {
            try { File.WriteAllText(reportPath, "{\"errorType\":\"" + error.GetType().FullName.Replace("\"", "'") + "\",\"errorMessage\":\"" + error.Message.Replace("\"", "'") + "\"}", Encoding.UTF8); } catch { }
            return 1;
        }
        finally
        {
            controller.Dispose();
        }
    }
}
