using GalaxyBudsClient.Platform;
using NUnit.Framework;

namespace GalaxyBudsClient.Tests;

[TestFixture]
public class NativeBudsReadScheduleTests
{
    [Test]
    public void OnlyNewObservationReplenishesAttemptsAndHealthyReadExpiryCanRefreshAgain()
    {
        var schedule = new NativeBudsReadSchedule();
        schedule.ShouldRead("view", true, false, false, 0, 10);
        Assert.That(schedule.ShouldRead("view", true, false, false, 2, 10), Is.True);
        Assert.That(schedule.ShouldRead("view", true, false, true, 3, 11), Is.False);
        schedule.ShouldRead("view", true, false, false, 34, 11);
        Assert.That(schedule.ShouldRead("view", true, false, false, 36, 11), Is.True);
        Assert.That(schedule.ShouldRead("view", true, false, false, 41, 11), Is.True);
        Assert.That(schedule.ShouldRead("view", true, false, false, 100, 11), Is.False);
        Assert.That(schedule.ShouldRead("view", true, false, true, 101, 11), Is.False, "Cached readiness is not another success");
        schedule.ShouldRead("view", true, false, false, 103, 11);
        Assert.That(schedule.ShouldRead("view", true, false, false, 105, 11), Is.False);
        schedule.ShouldRead("view", true, false, true, 106, 12);
        schedule.ShouldRead("view", true, false, false, 137, 12);
        Assert.That(schedule.ShouldRead("view", true, false, false, 139, 12), Is.True);
    }

    [Test]
    public void ScopeBaselineAndOldRevisionsDoNotPretendToBeNewSuccesses()
    {
        var schedule = new NativeBudsReadSchedule();
        schedule.ShouldRead("view", true, false, false, 0, 100);
        Assert.That(schedule.ShouldRead("view", true, false, false, 2, 100), Is.True);
        Assert.That(schedule.ShouldRead("view", true, false, false, 7, 100), Is.True);
        Assert.That(schedule.ShouldRead("view", true, false, false, 40, 99), Is.False);
        Assert.That(schedule.ShouldRead("view", true, false, false, 50, 100), Is.False);
        Assert.That(schedule.ShouldRead("view", false, true, false, 51, 100), Is.False);
        schedule.ShouldRead("view", true, false, false, 52, 100);
        Assert.That(schedule.ShouldRead("view", true, false, false, 54, 100), Is.False);
        schedule.ShouldRead("new-view", true, false, false, 55, 100);
        Assert.That(schedule.ShouldRead("new-view", true, false, false, 57, 100), Is.True);
    }
    [Test]
    public void WaitsForTwoStableSecondsAndDoesNotPollAHealthySession()
    {
        var schedule = new NativeBudsReadSchedule();
        Assert.That(schedule.ShouldRead("acq1", true, false, false, 0), Is.False);
        Assert.That(schedule.ShouldRead("acq1", true, false, false, 1.9), Is.False);
        Assert.That(schedule.ShouldRead("acq1", true, false, false, 2), Is.True);
        for (var t = 3; t < 100; t++)
            Assert.That(schedule.ShouldRead("acq1", true, false, true, t), Is.False);
    }

    [Test]
    public void AllowsOnlyOneReadRetryAndNeverResetsBudgetForErrorsOrBusyPolls()
    {
        var schedule = new NativeBudsReadSchedule();
        schedule.ShouldRead("acq1", true, false, false, 0);
        Assert.That(schedule.ShouldRead("acq1", true, false, false, 2), Is.True);
        Assert.That(schedule.ShouldRead("acq1", false, true, false, 3), Is.False);
        Assert.That(schedule.ShouldRead("acq1", true, false, false, 4), Is.False);
        Assert.That(schedule.ShouldRead("acq1", true, false, false, 6), Is.False);
        Assert.That(schedule.ShouldRead("acq1", true, false, false, 7), Is.True);
        for (var t = 8; t < 100; t++)
            Assert.That(schedule.ShouldRead("acq1", t % 2 == 0, t % 3 == 0, false, t), Is.False);
    }

    [Test]
    public void SupersedingAcquisitionAndSelectionReceiveTheirOwnStableBudget()
    {
        var schedule = new NativeBudsReadSchedule();
        schedule.ShouldRead("buds1/acq1", true, false, false, 0);
        Assert.That(schedule.ShouldRead("buds1/acq1", true, false, false, 2), Is.True);
        Assert.That(schedule.ShouldRead("buds2/acq2", true, false, false, 3), Is.False);
        Assert.That(schedule.ShouldRead("buds2/acq2", true, false, false, 5), Is.True);
        Assert.That(schedule.ShouldRead(null, false, false, false, 6), Is.False);
        Assert.That(schedule.ShouldRead("buds2/acq3", true, false, false, 7), Is.False);
        Assert.That(schedule.ShouldRead("buds2/acq3", true, false, false, 9), Is.True);
    }

    [Test]
    public void InterruptionsAndInvalidClockCannotAuthorizeARead()
    {
        var schedule = new NativeBudsReadSchedule();
        schedule.ShouldRead("acq1", true, false, false, 10);
        Assert.That(schedule.ShouldRead("acq1", true, false, false, double.NaN), Is.False);
        Assert.That(schedule.ShouldRead("acq1", true, false, false, 9), Is.False);
        Assert.That(schedule.ShouldRead("acq1", false, false, false, 11), Is.False);
        Assert.That(schedule.ShouldRead("acq1", true, false, false, 12), Is.False);
        Assert.That(schedule.ShouldRead("acq1", true, false, false, 14), Is.True);
    }
}
