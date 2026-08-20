using System;

public enum TrayHostHealth : byte
{
    Starting = 0,
    Ready = 1,
    Stopping = 2,
    Stopped = 3,
    Faulted = 4
}

public enum ShutdownReason : byte
{
    SupervisorExit = 1,
    Upgrade = 2,
    Uninstall = 3,
    ParentFault = 4
}

internal enum TrayHostControlKind : byte
{
    PresentationAck = 1,
    Shutdown = 2,
    ShutdownAck = 3,
    Ping = 4,
    Pong = 5,
    Fault = 6,
    UiReady = 7
}

internal enum TrayHostOutboundKind : byte
{
    Presentation = 1,
    Control = 2,
    Action = 3
}

public enum TrayHostEventKind : byte
{
    PresentationAck = 1,
    Action = 2,
    Fault = 3,
    Exited = 4
}

public sealed class TrayHostEvent
{
    public TrayHostEventKind Kind { get; internal set; }
    public Guid ActionId { get; internal set; }
    public TrayCommand Command { get; internal set; }
    public ulong Revision { get; internal set; }
    public string ErrorCode { get; internal set; }

    internal static TrayHostEvent Ack(ulong revision) { return new TrayHostEvent { Kind = TrayHostEventKind.PresentationAck, Revision = revision }; }
    internal static TrayHostEvent Fault(string code) { return new TrayHostEvent { Kind = TrayHostEventKind.Fault, ErrorCode = code ?? "CCOD_TRAYHOST_FAULT" }; }
    internal static TrayHostEvent Exited() { return new TrayHostEvent { Kind = TrayHostEventKind.Exited }; }
}

internal sealed class TrayHostControl
{
    internal TrayHostControlKind Kind { get; private set; }
    internal ShutdownReason Reason { get; private set; }
    internal ulong Revision { get; private set; }
    internal string ErrorCode { get; private set; }

    internal TrayHostControl(TrayHostControlKind kind, ShutdownReason reason, ulong revision)
    {
        Kind = kind;
        Reason = reason;
        Revision = revision;
    }

    internal TrayHostControl(TrayHostControlKind kind, string errorCode)
    {
        Kind = kind;
        ErrorCode = errorCode ?? String.Empty;
    }
}

internal sealed class TrayHostAction
{
    internal Guid ActionId { get; private set; }
    internal TrayCommand Command { get; private set; }
    internal ulong Revision { get; private set; }
    internal bool? BoolValue { get; private set; }
    internal LanguageMode? LanguageValue { get; private set; }

    internal TrayHostAction(Guid actionId, TrayCommand command, ulong revision)
    {
        if (actionId == Guid.Empty) { throw new ArgumentException("action id is required", "actionId"); }
        if (!Enum.IsDefined(typeof(TrayCommand), command) || command == TrayCommand.None) { throw new ArgumentException("command is invalid", "command"); }
        ActionId = actionId;
        Command = command;
        Revision = revision;
    }
}

internal sealed class TrayHostOutbound
{
    internal TrayHostOutboundKind Kind { get; private set; }
    internal PresentationSnapshot Presentation { get; private set; }
    internal TrayHostControl Control { get; private set; }
    internal TrayHostAction Action { get; private set; }

    internal static TrayHostOutbound FromPresentation(PresentationSnapshot value) { return new TrayHostOutbound { Kind = TrayHostOutboundKind.Presentation, Presentation = value }; }
    internal static TrayHostOutbound FromControl(TrayHostControl value) { return new TrayHostOutbound { Kind = TrayHostOutboundKind.Control, Control = value }; }
    internal static TrayHostOutbound FromAction(TrayHostAction value) { return new TrayHostOutbound { Kind = TrayHostOutboundKind.Action, Action = value }; }
}
