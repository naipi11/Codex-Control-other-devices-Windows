using System;

internal sealed class TrayHostApplication : IDisposable
{
    private readonly TrayWindow _window;
    private readonly Win32TrayPlatform _platform;
    private readonly Action<TrayCommand, ulong> _command;
    private readonly Action _work;
    private readonly uint _taskbarCreated;
    private bool _exitRequested;

    internal TrayHostApplication(TrayWindow window)
    {
        if (window == null) { throw new ArgumentNullException("window"); }
        _window = window;
    }

    internal TrayHostApplication(Win32TrayPlatform platform, TrayWindow window, Action<TrayCommand, ulong> command, Action work)
    {
        if (platform == null) { throw new ArgumentNullException("platform"); }
        if (window == null) { throw new ArgumentNullException("window"); }
        _platform = platform; _window = window; _command = command; _work = work; _taskbarCreated = (uint)Win32TrayPlatform.RegisterTaskbarCreatedMessage().ToInt64();
        _platform.SetMessageHandler(HandleMessage);
    }

    internal TrayWindow Window { get { return _window; } }

    internal int Run()
    {
        if (_platform == null) { return 0; }
        while (!_exitRequested)
        {
            Win32TrayPlatform.Message message;
            int result = Win32TrayPlatform.GetMessageLoop(out message);
            if (result <= 0) { break; }
            Win32TrayPlatform.TranslateAndDispatch(message);
        }
        return 0;
    }

    internal void PostWork() { if (_platform != null) { Win32TrayPlatform.PostToWindow(_window.OwnerHandle, TrayNativeConstants.WmApp + 2U); } }
    internal void RequestExit()
    {
        if (_exitRequested) { return; }
        _exitRequested = true;
        _window.RequestShutdown();
        Win32TrayPlatform.PostQuit(0);
    }

    internal static bool IsContextMenuEvent(uint message, IntPtr callbackData)
    {
        const uint wmContextMenu = 0x007bU;
        const uint wmRButtonUp = 0x0205U;
        if (message == wmContextMenu || message == wmRButtonUp) { return true; }
        if (message != TrayNativeConstants.WmApp + 1U) { return false; }
        uint eventCode = unchecked((uint)callbackData.ToInt64());
        return (eventCode & 0xffffU) == wmContextMenu || (eventCode & 0xffffU) == wmRButtonUp ||
               ((eventCode >> 16) & 0xffffU) == wmContextMenu || ((eventCode >> 16) & 0xffffU) == wmRButtonUp;
    }

    private void HandleMessage(uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == TrayNativeConstants.WmApp + 2U)
        {
            Action work = _work; if (work != null) { work(); }
            return;
        }
        if (message == _taskbarCreated)
        {
            _window.ReAddAfterTaskbarCreated();
            return;
        }
        if (message == 0x0012U || message == 0x0016U || message == 0x0011U)
        {
            RequestExit(); return;
        }
        if (IsContextMenuEvent(message, lParam))
        {
            TrayPoint point;
            if (!Win32TrayPlatform.GetCursorPosition(out point)) { point = new TrayPoint(0, 0); }
            try { _window.HandleContextMenu(point); } catch { }
        }
    }

    public void Dispose()
    {
        _window.Dispose();
    }
}
