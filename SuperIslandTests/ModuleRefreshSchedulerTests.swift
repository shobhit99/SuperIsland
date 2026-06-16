import XCTest
@testable import SuperIsland

@MainActor
final class ModuleRefreshSchedulerTests: XCTestCase {

    // Regression test for the main-thread freeze caused by leaked RunLoop timers.
    //
    // A module's refresh `action` can re-enter the scheduler (for example when a
    // refresh nudges AppState, which pushes a new activity state and triggers a
    // reschedule). The original implementation stored each Timer inside the Job
    // value type; `run(id:)` read a Job copy, invoked the action, then wrote the
    // stale copy back — clobbering any timer the re-entrant call had installed.
    // The clobbered timer stayed armed on RunLoop.main but lost its only owning
    // reference, so it could never be invalidated. Over days these orphans piled
    // up until __CFArmNextTimerInMode turned into an O(n) scan that pegged the
    // main thread and froze the UI.
    //
    // One job must own exactly one live timer no matter how often its action
    // re-enters the scheduler.
    func testReentrantActionDoesNotOrphanTimers() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        var runCount = 0

        scheduler.register(
            id: "test.job",
            name: "Test Job",
            policy: .interval(0.05, tolerance: 0.01),
            enabled: { true }
        ) { [weak scheduler] in
            runCount += 1
            // Re-enter mid-run, the way a real module refresh can.
            scheduler?.refreshScheduling()
        }

        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)

        for _ in 0..<200 {
            scheduler.runNow(id: "test.job")
        }

        XCTAssertGreaterThan(runCount, 0, "action should have executed")
        XCTAssertEqual(
            scheduler.scheduledTimerCountForTesting,
            scheduler.jobCountForTesting,
            "live timers must track the number of jobs, never accumulate"
        )
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)

        scheduler.unregister(id: "test.job")
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
    }

    // Repeated re-registration of the same id must not accumulate timers either.
    func testReRegisterKeepsSingleTimer() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)

        for _ in 0..<50 {
            scheduler.register(
                id: "test.job",
                name: "Test Job",
                policy: .interval(1, tolerance: 0.1),
                enabled: { true },
                action: {}
            )
        }

        XCTAssertEqual(scheduler.jobCountForTesting, 1)
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 1)

        scheduler.unregister(id: "test.job")
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
    }
}
