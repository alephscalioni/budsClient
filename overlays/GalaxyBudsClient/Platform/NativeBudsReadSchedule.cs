using System;

namespace GalaxyBudsClient.Platform;

/// <summary>Bounded read-only recovery, scoped to a confirmed Mac acquisition.</summary>
internal sealed class NativeBudsReadSchedule
{
    private string? _scope;
    private double? _stableSince;
    private double _lastAttempt = double.NegativeInfinity;
    private double _lastTime = double.NegativeInfinity;
    private int _attempts;
    private ulong _lastObservationRevision;

    internal bool ShouldRead(string? scope, bool eligible, bool busy, bool ready, double now, ulong observationRevision = 0)
    {
        if (!double.IsFinite(now) || now < _lastTime) return false;
        _lastTime = now;
        if (scope != _scope)
        {
            _scope = scope; _stableSince = null; _attempts = 0;
            _lastAttempt = double.NegativeInfinity;
            _lastObservationRevision = observationRevision;
        }
        else if (observationRevision > _lastObservationRevision)
        {
            _lastObservationRevision = observationRevision;
            // Only a new, accepted physical status replenishes failed attempts.
            // Cached readiness, ACKs and eligibility/busy flicker cannot do so.
            _attempts = 0;
        }
        if (string.IsNullOrEmpty(scope) || !eligible || busy || ready)
        {
            _stableSince = null;
            return false;
        }
        _stableSince ??= now;
        if (now - _stableSince < 2 || _attempts >= 2 || now - _lastAttempt < 5) return false;
        _attempts++; _lastAttempt = now;
        return true;
    }
}
