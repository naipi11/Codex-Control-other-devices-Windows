using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Threading;

internal static class TrayHostParentClientSelfTest
{
    private static void AssertTrue(bool value, string message) { if (!value) { throw new InvalidOperationException(message); } }

    private static PresentationSnapshot Snapshot(ulong revision)
    {
        string[] strings = new string[18];
        for (int i = 0; i < strings.Length; i++) { strings[i] = "string-" + i; }
        return new PresentationSnapshot(revision, TrayColor.Green, TrayState.Active, LanguageMode.Chinese, PresentationFlags.OpenLogsEnabled, strings);
    }

    private static Process StartPeer(ProcessStartInfo requested)
    {
        requested.Arguments = "--peer";
        requested.UseShellExecute = false;
        requested.CreateNoWindow = true;
        requested.RedirectStandardInput = true;
        requested.RedirectStandardOutput = true;
        requested.RedirectStandardError = true;
        return Process.Start(requested);
    }

    private static void RunPeer()
    {
        Stream input = Console.OpenStandardInput();
        Stream output = Console.OpenStandardOutput();
        ProtocolFrame parentHello = ProtocolCodec.ReadBootstrap(input, ProtocolDirection.ParentToHost);
        TrayHostHello hello = TrayHostWire.ReadParentHello(parentHello.Payload);
        byte[] hostNonce = new byte[32];
        using (RandomNumberGenerator rng = RandomNumberGenerator.Create()) { rng.GetBytes(hostNonce); }
        ulong epoch = 99UL;
        ProtocolCodec.WriteBootstrap(output, ProtocolFrame.Bootstrap(ProtocolDirection.HostToParent, TrayHostMessageType.HostHello, TrayHostWire.WriteHostHello(Process.GetCurrentProcess().Id, hello.RuntimeId, hostNonce, epoch)));
        SessionKeys keys = ProtocolCodec.DeriveDirectionalKeys(hello.SessionSeed, hello.ParentChallenge, hostNonce, epoch);
        ProtocolFrame presentation = ProtocolCodec.ReadAuthenticated(input, ProtocolDirection.ParentToHost, epoch, 1UL, keys.ParentToHost);
        AssertTrue(presentation.MessageType == TrayHostMessageType.Presentation, "peer receives initial presentation");
        ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.PresentationAck, epoch, 1UL, TrayHostWire.WriteRevision(TrayHostWire.ReadPresentation(presentation.Payload).Revision)), keys.HostToParent);
        ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.UiReady, epoch, 2UL, TrayHostWire.WriteRevision(TrayHostWire.ReadPresentation(presentation.Payload).Revision)), keys.HostToParent);
        ulong sequence = 3UL;
        while (true)
        {
            ProtocolFrame frame = ProtocolCodec.ReadAuthenticated(input, ProtocolDirection.ParentToHost, epoch, sequence - 1UL, keys.ParentToHost);
            if (frame.MessageType == TrayHostMessageType.Shutdown)
            {
                ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.ShutdownAck, epoch, sequence, frame.Payload), keys.HostToParent);
                return;
            }
            if (frame.MessageType == TrayHostMessageType.Presentation)
            {
                ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.PresentationAck, epoch, sequence, TrayHostWire.WriteRevision(TrayHostWire.ReadPresentation(frame.Payload).Revision)), keys.HostToParent);
            }
            else if (frame.MessageType == TrayHostMessageType.Ping)
            {
                ProtocolCodec.WriteAuthenticated(output, ProtocolFrame.Authenticated(ProtocolDirection.HostToParent, TrayHostMessageType.Pong, epoch, sequence, frame.Payload), keys.HostToParent);
            }
            sequence++;
        }
    }

    public static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] == "--peer") { RunPeer(); return 0; }
            TrayHostParentClient.TestProcessFactory = StartPeer;
            Process current = Process.GetCurrentProcess();
            TrayHostStartOptions options = new TrayHostStartOptions {
                ExePath = current.MainModule.FileName,
                RuntimeId = "test-runtime",
                ParentPid = current.Id,
                ParentCreationFileTimeUtc = current.StartTime.ToFileTimeUtc(),
                InitialPresentation = Snapshot(1UL)
            };
            TrayHostParentClient client = TrayHostParentClient.Start(options);
            AssertTrue(client.Receipt.ProtocolMajor == 1 && client.GetHealth() == TrayHostHealth.Ready, "parent waits for verified ready");
            AssertTrue(client.TryPublish(Snapshot(2UL)), "parent publishes presentation without blocking");
            AssertTrue(client.WaitForActivity(TimeSpan.FromSeconds(2)), "parent observes host acknowledgement");
            TrayHostEvent value;
            AssertTrue(client.TryDequeueEvent(out value) && value.Kind == TrayHostEventKind.PresentationAck && value.Revision == 2UL, "presentation acknowledgement is surfaced");
            AssertTrue(client.BeginShutdown(ShutdownReason.SupervisorExit, 2UL), "shutdown is accepted");
            AssertTrue(client.WaitForStopped(TimeSpan.FromSeconds(2)), "shutdown completes within deadline");
            client.Dispose();
            Console.WriteLine("TrayHost parent-client self-tests passed: 1");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("TrayHost parent-client self-test failed: " + error.GetType().FullName);
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}
