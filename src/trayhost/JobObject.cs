using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

internal sealed class JobObject : IDisposable
{
    private IntPtr _handle;
    private bool _disposed;

    private JobObject(IntPtr handle) { _handle = handle; }

    internal static JobObject CreateKillOnClose()
    {
        IntPtr handle = CreateJobObjectW(IntPtr.Zero, null);
        if (handle == IntPtr.Zero) { throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed"); }
        try
        {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = 0x00002000U;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(handle, 9U, buffer, (uint)size)) { throw new Win32Exception(Marshal.GetLastWin32Error(), "SetInformationJobObject failed"); }
            }
            finally { Marshal.FreeHGlobal(buffer); }
            return new JobObject(handle);
        }
        catch { CloseHandle(handle); throw; }
    }

    internal void Assign(Process process)
    {
        if (process == null || process.HasExited) { throw new InvalidOperationException("process is not assignable"); }
        if (!AssignProcessToJobObject(_handle, process.Handle)) { throw new Win32Exception(Marshal.GetLastWin32Error(), "AssignProcessToJobObject failed"); }
    }

    internal void Terminate(uint exitCode)
    {
        if (_handle != IntPtr.Zero) { TerminateJobObject(_handle, exitCode); }
    }

    public void Dispose()
    {
        if (_disposed) { return; }
        _disposed = true;
        IntPtr handle = _handle; _handle = IntPtr.Zero;
        if (handle != IntPtr.Zero) { CloseHandle(handle); }
    }

    [StructLayout(LayoutKind.Sequential)] private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        internal long PerProcessUserTimeLimit; internal long PerJobUserTimeLimit; internal uint LimitFlags; internal UIntPtr MinimumWorkingSetSize; internal UIntPtr MaximumWorkingSetSize; internal uint ActiveProcessLimit; internal long Affinity; internal uint PriorityClass; internal uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] private struct IO_COUNTERS { internal ulong ReadOperationCount; internal ulong WriteOperationCount; internal ulong OtherOperationCount; internal ulong ReadTransferCount; internal ulong WriteTransferCount; internal ulong OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)] private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION { internal JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; internal IO_COUNTERS IoInfo; internal UIntPtr ProcessMemoryLimit; internal UIntPtr JobMemoryLimit; internal UIntPtr PeakProcessMemoryUsed; internal UIntPtr PeakJobMemoryUsed; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(IntPtr job, uint infoClass, IntPtr info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
}
