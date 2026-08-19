import Testing
@testable import StenoPipeline

@Suite("Onboarding flow")
struct OnboardingFlowTests {
    @Test("language comes before models because assets are locale-bound")
    func languagePrecedesModels() {
        let pages = OnboardingFlow.Page.allCases
        let language = pages.firstIndex(of: .language)!
        let models = pages.firstIndex(of: .models)!
        #expect(language < models)
    }

    @Test("advancing walks every page and then finishes")
    func advanceWalksEveryPage() {
        var flow = OnboardingFlow()
        var seen: [OnboardingFlow.Page] = [flow.page]
        while !flow.isFinished {
            flow.advance()
            if !flow.isFinished { seen.append(flow.page) }
        }
        #expect(seen == OnboardingFlow.Page.allCases)
        #expect(flow.isFinished)
    }

    @Test("skipping a page does not skip the rest")
    func skipAdvancesByOne() {
        var flow = OnboardingFlow()
        flow.skip()
        #expect(flow.page == .profile)
    }

    @Test("a deliberate abort counts as finished so it does not reappear")
    func abortFinishes() {
        var flow = OnboardingFlow()
        flow.advance()
        flow.abort()
        #expect(flow.isFinished)
    }

    @Test("reopening starts at the first page again")
    func reopenRestarts() {
        var flow = OnboardingFlow()
        flow.abort()
        flow.reopen()
        #expect(flow.page == .welcome)
        #expect(!flow.isFinished)
    }
}
