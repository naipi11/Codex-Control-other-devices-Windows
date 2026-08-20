using System;
using System.Collections.Generic;

internal sealed class HostTransport : IDisposable
{
    private readonly object _gate = new object();
    private readonly Queue<TrayHostControl> _controls = new Queue<TrayHostControl>();
    private readonly Queue<TrayHostAction> _actions = new Queue<TrayHostAction>();
    private readonly Queue<Guid> _recentActionOrder = new Queue<Guid>();
    private readonly HashSet<Guid> _recentActions = new HashSet<Guid>();
    private PresentationSnapshot _pendingPresentation;
    private bool _menuOpen;
    private bool _disposed;

    internal void SetMenuOpen(bool value)
    {
        lock (_gate) { if (!_disposed) { _menuOpen = value; } }
    }

    internal bool TryAcceptPresentation(PresentationSnapshot snapshot)
    {
        if (snapshot == null) { return false; }
        lock (_gate)
        {
            if (_disposed) { return false; }
            if (_pendingPresentation == null || snapshot.Revision >= _pendingPresentation.Revision) { _pendingPresentation = snapshot; }
            return true;
        }
    }

    internal bool TryTakePresentation(out PresentationSnapshot snapshot)
    {
        lock (_gate)
        {
            if (_menuOpen || _pendingPresentation == null) { snapshot = null; return false; }
            snapshot = _pendingPresentation;
            _pendingPresentation = null;
            if (_controls.Count >= 16) { throw new InvalidOperationException("host control queue is exhausted"); }
            _controls.Enqueue(new TrayHostControl(TrayHostControlKind.PresentationAck, ShutdownReason.SupervisorExit, snapshot.Revision));
            return true;
        }
    }

    internal bool TryAcceptAction(TrayHostAction action)
    {
        if (action == null) { return false; }
        lock (_gate)
        {
            if (_disposed || _recentActions.Contains(action.ActionId) || _actions.Count >= 8) { return false; }
            _recentActions.Add(action.ActionId);
            _recentActionOrder.Enqueue(action.ActionId);
            while (_recentActionOrder.Count > 64) { _recentActions.Remove(_recentActionOrder.Dequeue()); }
            _actions.Enqueue(action);
            return true;
        }
    }

    internal bool TryDequeueAction(out TrayHostAction action)
    {
        lock (_gate)
        {
            if (_actions.Count == 0) { action = null; return false; }
            action = _actions.Dequeue();
            return true;
        }
    }

    internal bool TryDequeueControl(out TrayHostControl control)
    {
        lock (_gate)
        {
            if (_controls.Count == 0) { control = null; return false; }
            control = _controls.Dequeue();
            return true;
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) { return; }
            _disposed = true;
            _controls.Clear();
            _actions.Clear();
            _recentActions.Clear();
            _recentActionOrder.Clear();
            _pendingPresentation = null;
        }
    }
}
