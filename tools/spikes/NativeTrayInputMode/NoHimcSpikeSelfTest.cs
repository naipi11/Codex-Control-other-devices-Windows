using System;
using System.Collections.Generic;

internal sealed class FakeSpikeNative : ISpikeNative, ISpikeTrace
{
    internal readonly List<string> Calls = new List<string>();
    internal readonly List<string> Trace = new List<string>();
    internal IntPtr ContextValue;
    internal bool ForegroundResult = true;
    internal bool ForegroundProof = true;
    internal bool ReenterDuringTrack;
    internal NoHimcSpikeController Controller;
    internal int TrackCount;

    public IntPtr CreatePersistentOwner() { Calls.Add("CreateOwner"); return new IntPtr(11); }
    public IntPtr ImmAssociateContext(IntPtr hwnd, IntPtr himc) { Calls.Add(himc == IntPtr.Zero ? "Associate:null" : "Associate:restore"); return new IntPtr(99); }
    public IntPtr ImmGetContext(IntPtr hwnd) { Calls.Add("GetContext"); return ContextValue; }
    public bool ImmReleaseContext(IntPtr hwnd, IntPtr himc) { Calls.Add("ReleaseContext"); return true; }
    public bool SetForegroundWindow(IntPtr hwnd) { Calls.Add("SetForeground"); return ForegroundResult; }
    public IntPtr GetForegroundWindow() { Calls.Add("GetForeground"); return ForegroundProof ? new IntPtr(11) : new IntPtr(12); }
    public IntPtr CreatePopupMenu() { Calls.Add("CreateMenu"); return new IntPtr(22); }
    public bool AppendMenu(IntPtr menu, uint flags, UIntPtr commandId, string text) { Calls.Add("Append:" + text); return true; }
    public bool AppendSubMenu(IntPtr menu, IntPtr childMenu, string text) { Calls.Add("SubMenu:" + text); return true; }
    public uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr owner, IntPtr parameters)
    {
        Calls.Add("TrackPopup");
        TrackCount++;
        if (ReenterDuringTrack && Controller != null) { Controller.ShowMenu(new Point(2, 2)); }
        return 77;
    }
    public bool PostMessage(IntPtr hwnd, uint message, UIntPtr wParam, IntPtr lParam) { Calls.Add("WM_NULL"); return true; }
    public bool ShellNotifyIcon(uint message, ref NotifyIconData data) { Calls.Add("Notify:" + message); return true; }
    public bool DestroyMenu(IntPtr menu) { Calls.Add("DestroyMenu"); return true; }
    public bool DestroyWindow(IntPtr hwnd) { Calls.Add("DestroyWindow"); return true; }
    public void Record(string value) { Trace.Add(value); }
}

internal static class NoHimcSpikeSelfTest
{
    private static void AssertTrue(bool value, string message)
    {
        if (!value) { throw new InvalidOperationException(message); }
    }

    private static void AssertEqual(string expected, string actual, string message)
    {
        if (!String.Equals(expected, actual, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(message + " expected=[" + expected + "] actual=[" + actual + "]");
        }
    }

    private static FakeSpikeNative NewFake()
    {
        return new FakeSpikeNative();
    }

    private static void TestInitializationAndMenuOrder()
    {
        FakeSpikeNative fake = NewFake();
        NoHimcSpikeController controller = new NoHimcSpikeController(fake);
        controller.Initialize();
        UInt32 result = controller.ShowMenu(new Point(10, 20));
        AssertTrue(result == 77, "native command result is returned");
        AssertTrue(fake.Trace.Contains("MenuTrackStart") && fake.Trace.Contains("MenuReturn:77"), "diagnostic trace records menu tracking and return");
        AssertEqual(
            "CreateOwner|Associate:null|GetContext|Notify:0|Notify:4|CreateMenu|Append:Spike title|CreateMenu|Append:Chinese|Append:English|SubMenu:Language|Append:No-op|SetForeground|GetForeground|TrackPopup|WM_NULL|Notify:3|DestroyMenu",
            String.Join("|", fake.Calls.ToArray()),
            "initialization and native menu order is stable");
        controller.Dispose();
        string calls = String.Join("|", fake.Calls.ToArray());
        AssertTrue(calls.EndsWith("Associate:restore|Notify:2|DestroyWindow", StringComparison.Ordinal), "cleanup restores only the saved default HIMC; calls=" + calls);
    }

    private static void TestForegroundFailureDoesNotTrack()
    {
        FakeSpikeNative fake = NewFake();
        fake.ForegroundResult = false;
        NoHimcSpikeController controller = new NoHimcSpikeController(fake);
        controller.Initialize();
        AssertTrue(controller.ShowMenu(new Point(0, 0)) == 0, "foreground failure cancels safely");
        AssertTrue(fake.TrackCount == 0, "foreground failure never reaches TrackPopupMenuEx");
        controller.Dispose();
    }

    private static void TestForegroundProofFailureDoesNotTrack()
    {
        FakeSpikeNative fake = NewFake();
        fake.ForegroundProof = false;
        NoHimcSpikeController controller = new NoHimcSpikeController(fake);
        controller.Initialize();
        AssertTrue(controller.ShowMenu(new Point(0, 0)) == 0, "foreground proof failure cancels safely");
        AssertTrue(fake.TrackCount == 0, "foreground proof failure never reaches TrackPopupMenuEx");
        controller.Dispose();
    }

    private static void TestReentryDoesNotCreateSecondMenu()
    {
        FakeSpikeNative fake = NewFake();
        fake.ReenterDuringTrack = true;
        NoHimcSpikeController controller = new NoHimcSpikeController(fake);
        fake.Controller = controller;
        controller.Initialize();
        controller.ShowMenu(new Point(0, 0));
        int createCount = 0;
        foreach (string call in fake.Calls) { if (call == "CreateMenu") { createCount++; } }
        AssertTrue(createCount == 2 && fake.TrackCount == 1, "reentrant callback does not create a second menu; create=" + createCount + ";track=" + fake.TrackCount + ";calls=" + String.Join("|", fake.Calls.ToArray()));
        controller.Dispose();
    }

    private static void TestInvalidOwnerContextIsReleased()
    {
        FakeSpikeNative fake = NewFake();
        fake.ContextValue = new IntPtr(123);
        NoHimcSpikeController controller = new NoHimcSpikeController(fake);
        bool threw = false;
        try { controller.Initialize(); } catch (InvalidOperationException) { threw = true; }
        AssertTrue(threw, "an unexpected owner HIMC is rejected");
        AssertTrue(fake.Calls.Contains("ReleaseContext"), "unexpected HIMC is always released");
    }

    public static int Main(string[] args)
    {
        try
        {
            TestInitializationAndMenuOrder();
            TestForegroundFailureDoesNotTrack();
            TestForegroundProofFailureDoesNotTrack();
            TestReentryDoesNotCreateSecondMenu();
            TestInvalidOwnerContextIsReleased();
            Console.WriteLine("No-HIMC spike self-tests passed: 5");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("No-HIMC spike self-test failed: " + error.GetType().FullName);
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}
