using GalaxyBudsClient.Platform;
using NUnit.Framework;

namespace GalaxyBudsClient.Tests;

[TestFixture]
public class NativeBudsStartDrainTests
{
    [Test]
    public async Task StartupWaitsForActualZeroWithoutRetryingAnOperation()
    {
        var counts = new Queue<int?>([2, 1, 0]);
        var delays = 0;
        var ready = await NativeBudsStartDrain.WaitAsync(() => (true, counts.Dequeue()), () => false,
            () => { delays++; return Task.CompletedTask; });
        Assert.That(ready, Is.True);
        Assert.That(delays, Is.EqualTo(2));
        Assert.That(counts, Is.Empty);
    }

    [Test]
    public async Task StopDuringWaitCannotAuthorizeTheOldStart()
    {
        var cancelled = false;
        var reads = 0;
        var ready = await NativeBudsStartDrain.WaitAsync(() => { reads++; return (true, 1); }, () => cancelled,
            () => { cancelled = true; return Task.CompletedTask; });
        Assert.That(ready, Is.False);
        Assert.That(reads, Is.EqualTo(1));
    }

    [TestCase(null)]
    [TestCase(1)]
    public async Task UnknownOrUnfinishedWorkRemainsBoundedAndCannotAuthorizeStartup(int? pending)
    {
        var reads = 0;
        var ready = await NativeBudsStartDrain.WaitAsync(() => { reads++; return (true, pending); }, () => false,
            () => Task.CompletedTask, attempts: 3);
        Assert.That(ready, Is.False);
        Assert.That(reads, Is.EqualTo(3));
    }
    [Test]
    public async Task OldZeroBeforeNativePreparationWasAppliedCannotAuthorizeStartup()
    {
        var step = 0;
        var ready = await NativeBudsStartDrain.WaitAsync(() => step switch
        {
            0 => (false, 0),
            1 => (true, 1),
            _ => (true, 0)
        }, () => false, () => { step++; return Task.CompletedTask; });
        Assert.That(ready, Is.True);
        Assert.That(step, Is.EqualTo(2));
    }
}
