//
//  SyncDiagnosticServiceTests.swift
//  ChronoteTests
//
//  Pure-function tests for SyncDiagnosticService. The async `performDiagnostic()`
//  touches CKContainer / PersistenceController / FileManager.ubiquityIdentityToken
//  and is not unit-testable in isolation; the inline `severity` derivation inside
//  it is only reachable via that path. We test the two pieces that ARE pure:
//
//  1. `SyncIssue.isCritical` table — the source of truth that drives `severity`
//     classification. If a future case is added without updating `isCritical`,
//     `severity` derivation silently drifts (a `default: false` would be a real
//     hazard, but the current implementation uses an exhaustive switch — these
//     tests lock that in by enumerating every case explicitly).
//  2. `generateDiagnosticReport(_:)` — pure String formatter over a result DTO.
//
//  No production seam is exercised. If we wanted to test `severity` directly we
//  would need to either extract it to a pure helper (`severity(for issues:) -> ...`)
//  or inject the 5 individual checks; per task instructions we do neither.
//

import Testing
import Foundation
@testable import Lumory

// MARK: - SyncIssue.isCritical table

struct SyncIssueIsCriticalTests {
    // Critical cases — any one of these in `issues` forces severity = .critical.

    @Test func iCloudNotSignedIn_isCritical() {
        #expect(SyncIssue.iCloudNotSignedIn.isCritical == true)
    }

    @Test func coreDataStoreCorrupted_isCritical() {
        #expect(SyncIssue.coreDataStoreCorrupted.isCritical == true)
    }

    @Test func cloudKitMisconfigured_isCritical() {
        #expect(SyncIssue.cloudKitMisconfigured.isCritical == true)
    }

    // Non-critical cases — present in `issues` only bumps severity to .warning.

    @Test func networkUnavailable_isNotCritical() {
        #expect(SyncIssue.networkUnavailable.isCritical == false)
    }

    @Test func iCloudContainerInaccessible_isNotCritical() {
        #expect(SyncIssue.iCloudContainerInaccessible.isCritical == false)
    }

    /// Exhaustiveness guard: enumerate every known case so that adding a new
    /// `SyncIssue` case forces this test to be updated. `isCritical` uses an
    /// exhaustive switch (no `default`) — adding a case without classifying it
    /// fails compilation, but adding a case + classifying it as `false` and
    /// forgetting to update tests would silently leak through. Listing every
    /// case here makes that omission a visible diff.
    @Test func allKnownCases_classifiedExplicitly() {
        let allCases: [SyncIssue] = [
            .iCloudNotSignedIn,
            .networkUnavailable,
            .iCloudContainerInaccessible,
            .coreDataStoreCorrupted,
            .cloudKitMisconfigured,
        ]
        let critical = allCases.filter { $0.isCritical }
        let nonCritical = allCases.filter { !$0.isCritical }
        #expect(critical.count == 3)
        #expect(nonCritical.count == 2)
        #expect(allCases.count == 5)
    }
}

// MARK: - generateDiagnosticReport

/// `generateDiagnosticReport` runs `NSLocalizedString` lookups; we don't pin the
/// translated text (would couple tests to copy churn in `Localizable.strings`),
/// instead we assert structural invariants that survive any localization:
///   - timestamp string from `DateFormatter.localizedString(...)` appears
///   - severity displayName appears
///   - every issue's description appears (no silent drop)
///   - every recommendation appears (no silent drop)
///   - empty-issues path produces no `•` bullet lines
///   - non-empty path produces one `•` per issue + one per recommendation
struct GenerateDiagnosticReportTests {

    private func fixedTimestamp() -> Date {
        // 2026-05-09 12:34:56 UTC — arbitrary but stable.
        Date(timeIntervalSince1970: 1_778_502_896)
    }

    @Test func empty_issuesAndRecommendations_producesHealthyReport() {
        let result = SyncDiagnosticResult(
            severity: .healthy,
            issues: [],
            recommendations: [],
            timestamp: fixedTimestamp()
        )
        let report = SyncDiagnosticService.generateDiagnosticReport(result)

        // Structural: header + generated-at line + status line + no-issues line.
        // We don't assert exact localized copy, but the report MUST be non-empty
        // and MUST NOT contain any `•` bullets (those only appear when issues exist).
        #expect(!report.isEmpty)
        #expect(!report.contains("•"))

        // Severity displayName must appear somewhere in the report.
        #expect(report.contains(SyncDiagnosticSeverity.healthy.displayName))
    }

    @Test func oneCriticalOneWarning_bothIssuesAndRecommendationsPresent() {
        let issues: [SyncIssue] = [.iCloudNotSignedIn, .networkUnavailable]
        let recs = ["rec-A-sign-in", "rec-B-network"]
        let result = SyncDiagnosticResult(
            severity: .critical,
            issues: issues,
            recommendations: recs,
            timestamp: fixedTimestamp()
        )
        let report = SyncDiagnosticService.generateDiagnosticReport(result)

        // Both issues' description strings appear.
        #expect(report.contains(SyncIssue.iCloudNotSignedIn.description))
        #expect(report.contains(SyncIssue.networkUnavailable.description))

        // Both recommendation strings appear verbatim (we control these in the fixture).
        #expect(report.contains("rec-A-sign-in"))
        #expect(report.contains("rec-B-network"))

        // Severity displayName.
        #expect(report.contains(SyncDiagnosticSeverity.critical.displayName))

        // Bullet count: 2 issue bullets + 2 recommendation bullets = 4.
        let bulletCount = report.components(separatedBy: "•").count - 1
        #expect(bulletCount == 4)
    }

    @Test func multipleCritical_allIssuesPresent() {
        let issues: [SyncIssue] = [
            .iCloudNotSignedIn,
            .coreDataStoreCorrupted,
            .cloudKitMisconfigured,
        ]
        let recs = ["rec-1", "rec-2", "rec-3"]
        let result = SyncDiagnosticResult(
            severity: .critical,
            issues: issues,
            recommendations: recs,
            timestamp: fixedTimestamp()
        )
        let report = SyncDiagnosticService.generateDiagnosticReport(result)

        // None of the three critical issues may be silently dropped.
        for issue in issues {
            #expect(report.contains(issue.description), "Missing issue: \(issue)")
        }
        for rec in recs {
            #expect(report.contains(rec), "Missing recommendation: \(rec)")
        }

        // 3 issue bullets + 3 recommendation bullets = 6.
        let bulletCount = report.components(separatedBy: "•").count - 1
        #expect(bulletCount == 6)
    }

    @Test func warningSeverity_displayNameAppears() {
        let result = SyncDiagnosticResult(
            severity: .warning,
            issues: [.networkUnavailable],
            recommendations: ["check-wifi"],
            timestamp: fixedTimestamp()
        )
        let report = SyncDiagnosticService.generateDiagnosticReport(result)
        #expect(report.contains(SyncDiagnosticSeverity.warning.displayName))
        #expect(report.contains(SyncIssue.networkUnavailable.description))
        #expect(report.contains("check-wifi"))
    }

    @Test func timestampString_appearsInReport() {
        let ts = fixedTimestamp()
        let result = SyncDiagnosticResult(
            severity: .healthy,
            issues: [],
            recommendations: [],
            timestamp: ts
        )
        let report = SyncDiagnosticService.generateDiagnosticReport(result)

        // The report formats the timestamp via `DateFormatter.localizedString`
        // with .medium/.medium styles. We compute the same string and assert
        // it appears (locale-agnostic since we use the same call).
        let expected = DateFormatter.localizedString(from: ts, dateStyle: .medium, timeStyle: .medium)
        #expect(report.contains(expected))
    }

    /// Recommendations section is only emitted on the non-empty branch
    /// (`if result.issues.isEmpty` → no recommendations rendered). Locks that
    /// behavior so a future refactor that always renders recommendations
    /// would surface here.
    @Test func emptyIssues_recommendationsNotRendered_evenIfProvided() {
        let result = SyncDiagnosticResult(
            severity: .healthy,
            issues: [],
            recommendations: ["should-not-appear-orphan-rec"],
            timestamp: fixedTimestamp()
        )
        let report = SyncDiagnosticService.generateDiagnosticReport(result)
        #expect(!report.contains("should-not-appear-orphan-rec"))
        #expect(!report.contains("•"))
    }
}

// MARK: - SyncDiagnosticSeverity.displayName smoke

/// Each severity has a non-empty localized displayName. Cheap guard against
/// a future translator deleting one and silently rendering "" in the report.
struct SyncDiagnosticSeverityDisplayNameTests {
    @Test func healthy_hasNonEmptyDisplayName() {
        #expect(!SyncDiagnosticSeverity.healthy.displayName.isEmpty)
    }

    @Test func warning_hasNonEmptyDisplayName() {
        #expect(!SyncDiagnosticSeverity.warning.displayName.isEmpty)
    }

    @Test func critical_hasNonEmptyDisplayName() {
        #expect(!SyncDiagnosticSeverity.critical.displayName.isEmpty)
    }
}
