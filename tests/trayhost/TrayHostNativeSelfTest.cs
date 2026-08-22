using System;
using System.Collections.Generic;

internal sealed class FakeTrayPlatform : INativeTrayPlatform
{
    internal readonly List<string> Calls = new List<string>();
    internal bool ForegroundResult = true;
    internal bool ForegroundProof = true;
    internal bool ShowOwnerResult = true;
    internal IntPtr OwnerInputContext = IntPtr.Zero;
    internal uint TrackResult;
    internal bool SawNonzeroIcon;
    internal Action DuringTrack;
    internal int TrackCalls;
    internal readonly List<string> MessageBoxes = new List<string>();

    public IntPtr CreateOwner() { Calls.Add("CreateOwner"); return new IntPtr(10); }
    public IntPtr AssociateOwnerInputContext(IntPtr owner, IntPtr context) { Calls.Add(context == IntPtr.Zero ? "Associate:null" : "Associate:restore"); return new IntPtr(20); }
    public IntPtr GetOwnerInputContext(IntPtr owner) { Calls.Add("GetContext"); return OwnerInputContext; }
    public bool ReleaseInputContext(IntPtr owner, IntPtr context) { Calls.Add("ReleaseContext"); return true; }
    public IntPtr LoadIcon() { Calls.Add("LoadIcon"); return new IntPtr(40); }
    public bool DestroyIcon(IntPtr icon) { Calls.Add("DestroyIcon"); return true; }
    public bool AddIcon(ref TrayIconData icon) { SawNonzeroIcon = icon.hIcon != IntPtr.Zero; Calls.Add("NIM_ADD"); return true; }
    public bool SetIconVersion(ref TrayIconData icon) { Calls.Add("NIM_SETVERSION"); return true; }
    public bool DeleteIcon(ref TrayIconData icon) { Calls.Add("NIM_DELETE"); return true; }
    public IntPtr CreatePopupMenu() { Calls.Add("CreateMenu"); return new IntPtr(30); }
    public IntPtr CreateSubMenu() { return new IntPtr(31); }
    public bool AppendMenu(IntPtr menu, uint flags, UIntPtr command, string text) { Calls.Add("Append:" + text); return true; }
    public bool AppendSubMenu(IntPtr menu, IntPtr child, string text) { Calls.Add("SubMenu:" + text); return true; }
    public bool ShowOwner(IntPtr owner) { Calls.Add("ShowOwner"); return ShowOwnerResult; }
    public bool HideOwner(IntPtr owner) { Calls.Add("HideOwner"); return true; }
    public bool SetForegroundWindow(IntPtr owner) { Calls.Add("SetForeground"); return ForegroundResult; }
    public IntPtr GetForegroundWindow() { Calls.Add("GetForeground"); return ForegroundProof ? new IntPtr(10) : new IntPtr(11); }
    public uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters) { Calls.Add("Track"); TrackCalls++; if (DuringTrack != null) { DuringTrack(); } return TrackResult; }
    public bool PostMessage(IntPtr owner, uint message, UIntPtr wParam, IntPtr lParam) { Calls.Add("WM_NULL"); return true; }
    public bool SetNotificationFocus(ref TrayIconData icon) { Calls.Add("NIM_SETFOCUS"); return true; }
    public bool ShowMessageBox(IntPtr owner, string text, string caption) { MessageBoxes.Add(caption + "|" + text); Calls.Add("MessageBox"); return true; }
    public bool DestroyMenu(IntPtr menu) { Calls.Add("DestroyMenu"); return true; }
    public bool EndMenu() { Calls.Add("EndMenu"); return true; }
    public bool DestroyOwner(IntPtr owner) { Calls.Add("DestroyOwner"); return true; }
}

internal static class TrayHostNativeSelfTest
{
    private static void AssertTrue(bool value, string message) { if (!value) { throw new InvalidOperationException(message); } }
    private static void AssertEqual(string expected, string actual, string message) { if (!String.Equals(expected, actual, StringComparison.Ordinal)) { throw new InvalidOperationException(message + " expected=[" + expected + "] actual=[" + actual + "]"); } }

    private static PresentationSnapshot Snapshot(ulong revision)
    {
        string[] strings = new string[20];
        for (int i = 0; i < strings.Length; i++) { strings[i] = "s" + i; }
        return new PresentationSnapshot(revision, TrayColor.Green, TrayState.Active, LanguageMode.Chinese,
            PresentationFlags.SessionReadyVisible | PresentationFlags.ApplyNowVisible | PresentationFlags.ApplyNowEnabled |
            PresentationFlags.AutomationToggleEnabled | PresentationFlags.AutomationChecked | PresentationFlags.OpenLogsEnabled |
            PresentationFlags.UninstallEnabled, strings);
    }

    private static TrayWindow NewWindow(FakeTrayPlatform platform)
    {
        TrayWindow window = new TrayWindow(platform);
        window.Create(Snapshot(1));
        return window;
    }

    private static void TestNativeOrderAndCancel()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        TrayWindow window = NewWindow(platform);
        platform.TrackResult = 0;
        AssertTrue(window.HandleContextMenu(new TrayPoint(10, 20)) == 0, "cancel returns zero");
        AssertTrue(platform.SawNonzeroIcon, "NIM_ADD receives a valid HICON");
        AssertEqual("CreateOwner|Associate:null|GetContext|LoadIcon|NIM_ADD|NIM_SETVERSION|GetContext|GetContext|CreateMenu|Append:s0|Append:s1|Append:s2|Append:s3|Append:s4|Append:s5|Append:s6|SubMenu:s7|Append:s8|Append:s9|Append:s10|Append:s11|Append:s12|SubMenu:s13|Append:s14|Append:s15|Append:s16|ShowOwner|SetForeground|GetForeground|Track|WM_NULL|NIM_SETFOCUS|HideOwner|DestroyMenu", String.Join("|", platform.Calls.ToArray()), "native menu order is exact");
        window.Dispose();
    }

    private static void TestForegroundFailureFallsBackToNativeMenu()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        platform.ForegroundResult = false;
        TrayWindow window = NewWindow(platform);
        window.HandleContextMenu(new TrayPoint(0, 0));
        AssertTrue(platform.TrackCalls == 1, "foreground failure still tracks a native menu fallback");
        window.Dispose();
    }

    private static void TestOwnerShowFailureNeverTracks()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        platform.ShowOwnerResult = false;
        TrayWindow window = NewWindow(platform);
        window.HandleContextMenu(new TrayPoint(0, 0));
        AssertTrue(platform.TrackCalls == 0, "owner show failure never tracks a menu");
        window.Dispose();
    }

    private static void TestReentryAndPendingSnapshot()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        TrayWindow window = NewWindow(platform);
        platform.DuringTrack = delegate { AssertTrue(!window.HandleContextMenu(new TrayPoint(0, 0)).HasValue, "reentry returns no command"); window.Apply(Snapshot(2)); };
        platform.TrackResult = 0;
        window.HandleContextMenu(new TrayPoint(0, 0));
        AssertTrue(platform.TrackCalls == 1 && window.CurrentRevision == 2UL, "reentry is ignored and pending snapshot applies after close");
        window.Dispose();
    }

    private static void TestSelectedCommandAndTaskbarRestore()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        TrayWindow window = NewWindow(platform);
        TrayCommand selected = TrayCommand.None;
        window.CommandSelected += delegate(TrayCommand command, ulong revision) { selected = command; AssertTrue(revision == 1UL, "action revision is current"); };
        platform.TrackResult = (uint)TrayCommand.OpenLogs;
        window.HandleContextMenu(new TrayPoint(0, 0));
        AssertTrue(selected == TrayCommand.OpenLogs, "selected command is emitted once");
        platform.Calls.Clear();
        window.ReAddAfterTaskbarCreated();
        AssertEqual("NIM_ADD|NIM_SETVERSION", String.Join("|", platform.Calls.ToArray()), "Explorer restore re-adds and versions the icon");
        window.Dispose();
    }

    private static void TestAboutCommandShowsCurrentVersion()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        TrayWindow window = NewWindow(platform);
        platform.TrackResult = (uint)TrayCommand.ShowAbout;
        window.HandleContextMenu(new TrayPoint(0, 0));
        AssertTrue(platform.MessageBoxes.Count == 1, "about command shows one information box");
        AssertEqual("s12|s19", platform.MessageBoxes[0], "about uses the localized caption and runtime version text");
        window.Dispose();
    }

    private static void TestNoHimcFailureIsSafe()
    {
        FakeTrayPlatform platform = new FakeTrayPlatform();
        platform.OwnerInputContext = new IntPtr(99);
        TrayWindow window = new TrayWindow(platform);
        bool threw = false;
        try { window.Create(Snapshot(1)); } catch (InvalidOperationException) { threw = true; }
        AssertTrue(threw && platform.Calls.Contains("ReleaseContext"), "unexpected owner HIMC is released and creation fails");
    }

    private static void TestShellRightClickNotificationMapping()
    {
        AssertTrue(TrayHostApplication.IsContextMenuEvent(0x007bU, IntPtr.Zero), "WM_CONTEXTMENU opens the native menu");
        AssertTrue(TrayHostApplication.IsContextMenuEvent(0x0205U, IntPtr.Zero), "WM_RBUTTONUP opens the native menu");
        AssertTrue(TrayHostApplication.IsContextMenuEvent(TrayNativeConstants.WmApp + 1U, new IntPtr(0x0205)), "version-4 callback WM_RBUTTONUP opens the native menu");
        AssertTrue(TrayHostApplication.IsContextMenuEvent(TrayNativeConstants.WmApp + 1U, new IntPtr(0x007b), IntPtr.Zero), "legacy callback WM_CONTEXTMENU in wParam opens the native menu");
        AssertTrue(TrayHostApplication.IsContextMenuEvent(TrayNativeConstants.WmApp + 1U, new IntPtr(0x0205), IntPtr.Zero), "legacy callback WM_RBUTTONUP in wParam opens the native menu");
        AssertTrue(!TrayHostApplication.IsContextMenuEvent(TrayNativeConstants.WmApp + 1U, new IntPtr(0x0201)), "left click remains inert");
    }

    private static void TestRealNativePInvokeSurface()
    {
        Win32TrayPlatform platform = new Win32TrayPlatform();
        IntPtr owner = platform.CreateOwner();
        IntPtr menu = IntPtr.Zero;
        try
        {
            AssertTrue(owner != IntPtr.Zero, "real native owner is created");
            AssertTrue(platform.ShowOwner(owner), "real ShowWindow entry point resolves");
            menu = platform.CreatePopupMenu();
            AssertTrue(menu != IntPtr.Zero, "real CreatePopupMenu entry point resolves");
            AssertTrue(platform.AppendMenu(menu, TrayNativeConstants.MfString, new UIntPtr(1U), "probe"), "real AppendMenu entry point resolves");
            platform.SetForegroundWindow(owner);
            platform.GetForegroundWindow();
        }
        finally
        {
            if (menu != IntPtr.Zero) { platform.DestroyMenu(menu); }
            platform.HideOwner(owner);
            platform.DestroyOwner(owner);
        }
    }

    public static int Main(string[] args)
    {
        try
        {
            TestNativeOrderAndCancel();
            TestForegroundFailureFallsBackToNativeMenu();
            TestOwnerShowFailureNeverTracks();
            TestReentryAndPendingSnapshot();
            TestSelectedCommandAndTaskbarRestore();
            TestAboutCommandShowsCurrentVersion();
            TestNoHimcFailureIsSafe();
            TestShellRightClickNotificationMapping();
            TestRealNativePInvokeSurface();
            Console.WriteLine("TrayHost native self-tests passed: 5");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("TrayHost native self-test failed: " + error.GetType().FullName);
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}
