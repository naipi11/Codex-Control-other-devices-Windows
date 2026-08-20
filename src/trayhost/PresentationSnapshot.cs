using System;
using System.Collections.Generic;

public enum TrayColor : byte { Gray = 0, Green = 1, Yellow = 2, Red = 3 }
public enum LanguageMode : byte { System = 0, Chinese = 1, English = 2 }
public enum TrayState : byte { Waiting, Inspecting, Transitioning, Active, ActivePaused, RendererHandoff, Suppressed, Recovered, Error }

[Flags]
public enum PresentationFlags : uint
{
    None = 0,
    SessionReadyVisible = 1u << 0,
    ApplyNowVisible = 1u << 1,
    ApplyNowEnabled = 1u << 2,
    ManualRetryVisible = 1u << 3,
    ManualRetryEnabled = 1u << 4,
    AutomationToggleEnabled = 1u << 5,
    AutomationChecked = 1u << 6,
    CandidateOptInToggleEnabled = 1u << 7,
    CandidateOptInChecked = 1u << 8,
    OpenLogsEnabled = 1u << 9,
    UninstallEnabled = 1u << 10,
    Busy = 1u << 11
}

public sealed class PresentationSnapshot
{
    public ulong Revision { get; private set; }
    public TrayColor Color { get; private set; }
    public TrayState State { get; private set; }
    public LanguageMode Language { get; private set; }
    public PresentationFlags Flags { get; private set; }
    public IReadOnlyList<string> Strings { get; private set; }

    public PresentationSnapshot(ulong revision, TrayColor color, TrayState state, LanguageMode language, PresentationFlags flags, string[] strings)
    {
        if (revision == 0UL) { throw new ArgumentException("revision must be positive", "revision"); }
        if (!Enum.IsDefined(typeof(TrayColor), color) || !Enum.IsDefined(typeof(TrayState), state) || !Enum.IsDefined(typeof(LanguageMode), language)) { throw new ArgumentException("presentation enum is invalid"); }
        if ((((uint)flags) & ~0x00000fffu) != 0u) { throw new ArgumentException("presentation flags are invalid", "flags"); }
        if (strings == null || strings.Length != 18) { throw new ArgumentException("presentation string count is invalid", "strings"); }
        string[] copy = (string[])strings.Clone();
        for (int i = 0; i < copy.Length; i++)
        {
            if (String.IsNullOrEmpty(copy[i]) || copy[i].Length > 300) { throw new ArgumentException("presentation string length is invalid", "strings"); }
            for (int j = 0; j < copy[i].Length; j++) { if (Char.IsControl(copy[i][j])) { throw new ArgumentException("presentation string contains a control character", "strings"); } }
        }
        Revision = revision;
        Color = color;
        State = state;
        Language = language;
        Flags = flags;
        Strings = Array.AsReadOnly(copy);
    }
}
