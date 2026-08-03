using System;
using System.Threading;
using System.Threading.Tasks;

namespace NostrVpn.Windows.ViewModels;

internal sealed class NativeCoreCallGate
{
    private readonly SemaphoreSlim _gate = new(1, 1);

    internal IDisposable? TryEnterRefresh()
    {
        return _gate.Wait(0) ? new Lease(_gate) : null;
    }

    internal async Task<IDisposable> EnterDispatchAsync()
    {
        await _gate.WaitAsync();
        return new Lease(_gate);
    }

    private sealed class Lease(SemaphoreSlim gate) : IDisposable
    {
        private SemaphoreSlim? _gate = gate;

        public void Dispose()
        {
            Interlocked.Exchange(ref _gate, null)?.Release();
        }
    }
}
