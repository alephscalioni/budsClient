using System;
using System.Threading.Tasks;

namespace GalaxyBudsClient.Platform;

/// Waits for cancellation already requested by switch.preparing. Does not open,
/// retry or replace SDK work, and an unknown count never authorizes startup.
internal static class NativeBudsStartDrain
{
    internal static async Task<bool> WaitAsync(Func<(bool applied, int? pending)> read, Func<bool> cancelled,
        Func<Task> delay, int attempts = 100)
    {
        for (var attempt = 0; attempt < attempts; attempt++)
        {
            if (cancelled()) return false;
            var state = read();
            if (state.applied && state.pending == 0) return !cancelled();
            await delay();
        }
        return false;
    }
}
