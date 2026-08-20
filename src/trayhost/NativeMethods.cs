using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

internal static class TrayNativeConstants
{
    internal const int WsPopup = unchecked((int)0x80000000);
    internal const int WsExToolWindow = 0x00000080;
    internal const uint MfString = 0x00000000;
    internal const uint MfSeparator = 0x00000800;
    internal const uint MfGrayed = 0x00000001;
    internal const uint MfDisabled = 0x00000002;
    internal const uint MfChecked = 0x00000008;
    internal const uint MfPopup = 0x00000010;
    internal const uint MfByPosition = 0x00000400;
    internal const uint TpmReturnCmd = 0x00000100;
    internal const uint TpmRightButton = 0x00000002;
    internal const uint TpmNoNotify = 0x00000080;
    internal const uint TpmLayoutRtl = 0x00004000;
    internal const uint WmNull = 0x0000;
    internal const uint WmApp = 0x8000;
    internal const uint NimAdd = 0x00000000;
    internal const uint NimModify = 0x00000001;
    internal const uint NimDelete = 0x00000002;
    internal const uint NimSetFocus = 0x00000003;
    internal const uint NimSetVersion = 0x00000004;
    internal const uint NotifyIconVersion4 = 4;
    internal const uint NifMessage = 0x00000001;
    internal const uint NifIcon = 0x00000002;
    internal const uint NifTip = 0x00000004;
    internal const uint SwpNoActivate = 0x0010;
    internal const int IdiApplication = 32512;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct TrayIconData
{
    internal int cbSize;
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

internal struct TrayPoint
{
    internal int X;
    internal int Y;

    internal TrayPoint(int x, int y)
    {
        X = x;
        Y = y;
    }
}

internal interface INativeTrayPlatform
{
    IntPtr CreateOwner();
    IntPtr AssociateOwnerInputContext(IntPtr owner, IntPtr context);
    IntPtr GetOwnerInputContext(IntPtr owner);
    bool ReleaseInputContext(IntPtr owner, IntPtr context);
    bool AddIcon(ref TrayIconData icon);
    bool SetIconVersion(ref TrayIconData icon);
    bool DeleteIcon(ref TrayIconData icon);
    IntPtr CreatePopupMenu();
    IntPtr CreateSubMenu();
    bool AppendMenu(IntPtr menu, uint flags, UIntPtr command, string text);
    bool AppendSubMenu(IntPtr menu, IntPtr child, string text);
    bool SetForegroundWindow(IntPtr owner);
    IntPtr GetForegroundWindow();
    uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters);
    bool PostMessage(IntPtr owner, uint message, UIntPtr wParam, IntPtr lParam);
    bool SetNotificationFocus(ref TrayIconData icon);
    bool DestroyMenu(IntPtr menu);
    bool EndMenu();
    bool DestroyOwner(IntPtr owner);
}

internal sealed class Win32TrayPlatform : INativeTrayPlatform
{
    private const string StaticClass = "STATIC";

    public IntPtr CreateOwner()
    {
        IntPtr owner = CreateWindowExW(
            TrayNativeConstants.WsExToolWindow,
            StaticClass,
            "CodexRemote-fix",
            TrayNativeConstants.WsPopup,
            -32000,
            -32000,
            1,
            1,
            IntPtr.Zero,
            IntPtr.Zero,
            GetModuleHandleW(null),
            IntPtr.Zero);
        if (owner == IntPtr.Zero) { throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateOwner failed"); }
        return owner;
    }

    public IntPtr AssociateOwnerInputContext(IntPtr owner, IntPtr context) { return ImmAssociateContext(owner, context); }
    public IntPtr GetOwnerInputContext(IntPtr owner) { return ImmGetContext(owner); }
    public bool ReleaseInputContext(IntPtr owner, IntPtr context) { return ImmReleaseContext(owner, context); }

    public bool AddIcon(ref TrayIconData icon) { return Shell_NotifyIconW(TrayNativeConstants.NimAdd, ref icon); }
    public bool SetIconVersion(ref TrayIconData icon)
    {
        icon.uFlags = 0;
        icon.uTimeoutOrVersion = TrayNativeConstants.NotifyIconVersion4;
        return Shell_NotifyIconW(TrayNativeConstants.NimSetVersion, ref icon);
    }
    public bool DeleteIcon(ref TrayIconData icon) { return Shell_NotifyIconW(TrayNativeConstants.NimDelete, ref icon); }
    public bool SetNotificationFocus(ref TrayIconData icon) { return Shell_NotifyIconW(TrayNativeConstants.NimSetFocus, ref icon); }

    public IntPtr CreatePopupMenu() { return CreatePopupMenuNative(); }
    public IntPtr CreateSubMenu() { return CreatePopupMenuNative(); }
    public bool AppendMenu(IntPtr menu, uint flags, UIntPtr command, string text) { return AppendMenuW(menu, flags, command, text ?? String.Empty); }
    public bool AppendSubMenu(IntPtr menu, IntPtr child, string text) { return AppendMenuW(menu, TrayNativeConstants.MfPopup | TrayNativeConstants.MfString, new UIntPtr(unchecked((ulong)child.ToInt64())), text ?? String.Empty); }
    public bool SetForegroundWindow(IntPtr owner) { return SetForegroundWindowNative(owner); }
    public IntPtr GetForegroundWindow() { return GetForegroundWindowNative(); }
    public uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters) { return TrackPopupMenuExNative(menu, flags, x, y, owner, parameters); }
    public bool PostMessage(IntPtr owner, uint message, UIntPtr wParam, IntPtr lParam) { return PostMessageW(owner, message, wParam, lParam); }
    public bool DestroyMenu(IntPtr menu) { return DestroyMenuNative(menu); }
    public bool EndMenu() { return EndMenuNative(); }
    public bool DestroyOwner(IntPtr owner) { return DestroyWindow(owner); }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowExW(int exStyle, string className, string windowName, int style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandleW(string moduleName);
    [DllImport("imm32.dll", SetLastError = true)] private static extern IntPtr ImmAssociateContext(IntPtr window, IntPtr context);
    [DllImport("imm32.dll", SetLastError = true)] private static extern IntPtr ImmGetContext(IntPtr window);
    [DllImport("imm32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ImmReleaseContext(IntPtr window, IntPtr context);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Shell_NotifyIconW(uint message, ref TrayIconData data);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr CreatePopupMenuNative();
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AppendMenuW(IntPtr menu, uint flags, UIntPtr newItem, string text);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindowNative(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr GetForegroundWindowNative();
    [DllImport("user32.dll", SetLastError = true)] private static extern uint TrackPopupMenuExNative(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostMessageW(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyMenuNative(IntPtr menu);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EndMenuNative();
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyWindow(IntPtr window);
}
