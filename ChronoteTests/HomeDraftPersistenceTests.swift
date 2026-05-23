import Foundation
import Testing
@testable import Lumory

@MainActor
struct HomeDraftPersistenceTests {
    @Test func persistDraft_roundTripsPastDateAndClearsWithEmptyText() {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(byAdding: .day, value: -3, to: Date())!

        HomeView.persistDraft("remember this", date: date)
        #expect(HomeView.persistedDraftText() == "remember this")
        #expect(HomeView.persistedDraftDate() == Calendar.current.startOfDay(for: date))

        HomeView.persistDraft("", date: nil)
        #expect(HomeView.persistedDraftText() == nil)
        #expect(HomeView.persistedDraftDate() == nil)
    }

    @Test func persistDraftDate_ignoresTodayAndFutureDates() {
        HomeView.persistDraft("draft", date: Date())
        #expect(HomeView.persistedDraftDate() == nil)

        let future = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        HomeView.persistDraft("draft", date: future)
        #expect(HomeView.persistedDraftDate() == nil)

        HomeView.persistDraft("", date: nil)
    }
}
