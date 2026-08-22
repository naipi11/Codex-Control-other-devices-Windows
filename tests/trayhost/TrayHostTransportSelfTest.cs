using System;
using System.Collections.Generic;

internal static class TrayHostTransportSelfTest
{
    private static void AssertTrue(bool value, string message)
    {
        if (!value) { throw new InvalidOperationException(message); }
    }

    private static PresentationSnapshot Snapshot(ulong revision)
    {
        string[] strings = new string[20];
        for (int i = 0; i < strings.Length; i++) { strings[i] = "string-" + i; }
        return new PresentationSnapshot(revision, TrayColor.Green, TrayState.Active, LanguageMode.Chinese, PresentationFlags.OpenLogsEnabled, strings);
    }

    private static void TestParentLatestAndReservedControl()
    {
        ParentTransport transport = new ParentTransport();
        AssertTrue(transport.TrySetLatestPresentation(Snapshot(1)), "first presentation accepted");
        AssertTrue(transport.TrySetLatestPresentation(Snapshot(2)), "latest presentation replaces pending state");
        PresentationSnapshot latest;
        AssertTrue(transport.TryDequeueLatestPresentation(out latest) && latest.Revision == 2UL, "only newest presentation is dequeued");
        AssertTrue(transport.TryEnqueueAction(new TrayHostAction(Guid.NewGuid(), TrayCommand.OpenLogs, 2UL)), "first action accepted");
        for (int i = 0; i < 7; i++) { AssertTrue(transport.TryEnqueueAction(new TrayHostAction(Guid.NewGuid(), TrayCommand.OpenLogs, 2UL)), "action queue remains bounded through eight entries"); }
        AssertTrue(!transport.TryEnqueueAction(new TrayHostAction(Guid.NewGuid(), TrayCommand.OpenLogs, 2UL)), "ninth action is rejected");
        AssertTrue(transport.TryEnqueueControl(new TrayHostControl(TrayHostControlKind.Shutdown, ShutdownReason.SupervisorExit, 2UL)), "shutdown control is reserved");
        TrayHostOutbound outbound;
        AssertTrue(transport.TryDequeueOutbound(out outbound) && outbound.Kind == TrayHostOutboundKind.Control, "control drains before actions");
        transport.Dispose();
    }

    private static void TestBrokenPipeAndStderrCap()
    {
        ParentTransport transport = new ParentTransport();
        byte[] noise = new byte[8192];
        transport.RecordStderr(noise);
        AssertTrue(transport.StderrBytesRetained == 4096, "stderr diagnostic retention is capped at 4 KiB");
        transport.MarkPipeBroken("CCOD_PIPE_BROKEN");
        AssertTrue(transport.GetHealth() == TrayHostHealth.Faulted, "broken pipe enters faulted health");
        transport.Dispose();
    }

    private static void TestHostPendingAndReplayBound()
    {
        HostTransport transport = new HostTransport();
        transport.SetMenuOpen(true);
        AssertTrue(transport.TryAcceptPresentation(Snapshot(1)), "host accepts first presentation");
        AssertTrue(transport.TryAcceptPresentation(Snapshot(2)), "host coalesces a newer presentation while menu is open");
        PresentationSnapshot ignored;
        AssertTrue(!transport.TryTakePresentation(out ignored), "menu-open presentation is not applied early");
        transport.SetMenuOpen(false);
        PresentationSnapshot newest;
        AssertTrue(transport.TryTakePresentation(out newest) && newest.Revision == 2UL, "menu close applies newest snapshot only");
        TrayHostControl control;
        AssertTrue(transport.TryDequeueControl(out control) && control.Kind == TrayHostControlKind.PresentationAck && control.Revision == 2UL, "one ack is emitted for the applied revision");
        Guid actionId = Guid.NewGuid();
        AssertTrue(transport.TryAcceptAction(new TrayHostAction(actionId, TrayCommand.OpenLogs, 2UL)), "first action accepted");
        AssertTrue(!transport.TryAcceptAction(new TrayHostAction(actionId, TrayCommand.OpenLogs, 2UL)), "replayed action id is rejected");
        for (int i = 0; i < 63; i++)
        {
            AssertTrue(transport.TryAcceptAction(new TrayHostAction(Guid.NewGuid(), TrayCommand.OpenLogs, 2UL)), "replay cache accepts distinct ids");
            TrayHostAction drained;
            AssertTrue(transport.TryDequeueAction(out drained), "host action queue drains independently");
        }
        AssertTrue(!transport.TryAcceptAction(new TrayHostAction(actionId, TrayCommand.OpenLogs, 2UL)), "the 64-entry replay cache rejects a replayed id");
        transport.Dispose();
    }

    public static int Main(string[] args)
    {
        try
        {
            TestParentLatestAndReservedControl();
            TestBrokenPipeAndStderrCap();
            TestHostPendingAndReplayBound();
            Console.WriteLine("TrayHost transport self-tests passed: 3");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("TrayHost transport self-test failed: " + error.GetType().FullName);
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}
