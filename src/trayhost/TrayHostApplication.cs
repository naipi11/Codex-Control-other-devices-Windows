using System;

internal sealed class TrayHostApplication : IDisposable
{
    private readonly TrayWindow _window;

    internal TrayHostApplication(TrayWindow window)
    {
        if (window == null) { throw new ArgumentNullException("window"); }
        _window = window;
    }

    internal TrayWindow Window { get { return _window; } }

    internal int Run()
    {
        return 0;
    }

    public void Dispose()
    {
        _window.Dispose();
    }
}
