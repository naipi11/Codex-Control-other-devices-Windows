using System;

internal sealed class InputModeGuard : IDisposable
{
    private readonly INativeTrayPlatform _native;
    private IntPtr _owner;
    private IntPtr _savedDefault;
    private bool _detached;

    internal InputModeGuard(INativeTrayPlatform native)
    {
        if (native == null) { throw new ArgumentNullException("native"); }
        _native = native;
    }

    internal void DetachOwnerInputContext(IntPtr owner)
    {
        if (_detached) { throw new InvalidOperationException("input context is already detached"); }
        _owner = owner;
        _savedDefault = _native.AssociateOwnerInputContext(owner, IntPtr.Zero);
        _detached = true;
    }

    internal bool VerifyNoOwnerInputContext(IntPtr owner)
    {
        if (!_detached || owner != _owner) { throw new InvalidOperationException("input context guard owner is invalid"); }
        IntPtr context = _native.GetOwnerInputContext(owner);
        if (context != IntPtr.Zero)
        {
            _native.ReleaseInputContext(owner, context);
            throw new InvalidOperationException("tray owner unexpectedly has an input context");
        }
        return true;
    }

    internal void RestoreOwnerDefaultContext(IntPtr owner)
    {
        if (!_detached) { return; }
        if (owner != _owner) { throw new InvalidOperationException("input context restore owner is invalid"); }
        _native.AssociateOwnerInputContext(owner, _savedDefault);
        _detached = false;
        _owner = IntPtr.Zero;
        _savedDefault = IntPtr.Zero;
    }

    public void Dispose()
    {
        if (_detached) { RestoreOwnerDefaultContext(_owner); }
    }
}
