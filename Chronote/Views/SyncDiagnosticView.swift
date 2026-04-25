import SwiftUI

struct SyncDiagnosticView: View {
    let result: SyncDiagnosticResult?
    @Environment(\.dismiss) private var dismiss
    @State private var showingFullReport = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let result = result {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: iconForSeverity(result.severity))
                            .font(.system(size: 48))
                            .foregroundColor(colorForSeverity(result.severity))
                        
                        Text(NSLocalizedString("sync.diagnostic.title", comment: "Sync diagnostic title"))
                            .font(.title)
                            .fontWeight(.bold)
                        
                        Text(result.severity.displayName)
                            .font(.headline)
                            .foregroundColor(colorForSeverity(result.severity))
                    }
                    .padding(.top)
                    
                    Divider()
                    
                    // Issues and Recommendations
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if result.issues.isEmpty {
                                // All good
                                VStack(spacing: 12) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 32))
                                        .foregroundColor(.green)
                                    
                                    Text(NSLocalizedString("sync.diagnostic.noIssues.title", comment: "No sync issues title"))
                                        .font(.headline)
                                    
                                    Text(NSLocalizedString("sync.diagnostic.noIssues.message", comment: "No sync issues message"))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(12)
                            } else {
                                // Issues found
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(NSLocalizedString("sync.diagnostic.issuesFound", comment: "Issues found heading"))
                                        .font(.headline)
                                        .foregroundColor(.red)
                                    
                                    ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                                        HStack(alignment: .top, spacing: 12) {
                                            let iconName = issue.isCritical
                                                ? "exclamationmark.triangle.fill"
                                                : "exclamationmark.circle.fill"
                                            Image(systemName: iconName)
                                                .foregroundColor(issue.isCritical ? .red : .orange)
                                            
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(issue.description)
                                                    .font(.subheadline)
                                                    .fontWeight(.medium)
                                                
                                                if issue.isCritical {
                                                    Text(NSLocalizedString(
                                                        "sync.diagnostic.criticalIssue",
                                                        comment: "Critical issue badge"
                                                    ))
                                                        .font(.caption)
                                                        .foregroundColor(.red)
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 2)
                                                        .background(Color.red.opacity(0.1))
                                                        .cornerRadius(4)
                                                }
                                            }
                                            
                                            Spacer()
                                        }
                                        .padding()
                                        .background(Color.red.opacity(0.05))
                                        .cornerRadius(8)
                                    }
                                }
                                
                                // Recommendations
                                if !result.recommendations.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(NSLocalizedString("sync.diagnostic.recommendations", comment: "Recommendations heading"))
                                            .font(.headline)
                                            .foregroundColor(.blue)
                                        
                                        ForEach(Array(result.recommendations.enumerated()), id: \.offset) { _, recommendation in
                                            HStack(alignment: .top, spacing: 12) {
                                                Image(systemName: "lightbulb.fill")
                                                    .foregroundColor(.blue)
                                                
                                                Text(recommendation)
                                                    .font(.subheadline)
                                                
                                                Spacer()
                                            }
                                            .padding()
                                            .background(Color.blue.opacity(0.05))
                                            .cornerRadius(8)
                                        }
                                    }
                                }
                            }
                            
                            // Timestamp
                            Text("\(NSLocalizedString("sync.diagnostic.generated", comment: "Generated timestamp label")): \(result.timestamp, style: .date) \(result.timestamp, style: .time)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top)
                        }
                        .padding()
                    }
                    
                    // Action buttons
                    HStack(spacing: 16) {
                        Button(NSLocalizedString("sync.diagnostic.showFullReport", comment: "Show full diagnostic report button")) {
                            showingFullReport = true
                        }
                        .buttonStyle(.glass)

                        Spacer()

                        Button(NSLocalizedString("完成", comment: "Done button")) {
                            dismiss()
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .padding()
                } else {
                    // No result
                    VStack(spacing: 16) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        
                        Text(NSLocalizedString("sync.diagnostic.noResult.title", comment: "No diagnostic result title"))
                            .font(.headline)
                        
                        Text(NSLocalizedString("sync.diagnostic.noResult.message", comment: "No diagnostic result message"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Button(NSLocalizedString("关闭", comment: "Close")) {
                            dismiss()
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("sync.diagnostic.title", comment: "Sync diagnostic title"))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .frame(minWidth: 500, minHeight: 400)
        .sheet(isPresented: $showingFullReport) {
            if let result = result {
                FullDiagnosticReportView(result: result)
            }
        }
    }
    
    private func iconForSeverity(_ severity: SyncDiagnosticSeverity) -> String {
        switch severity {
        case .healthy:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .critical:
            return "xmark.circle.fill"
        }
    }
    
    private func colorForSeverity(_ severity: SyncDiagnosticSeverity) -> Color {
        switch severity {
        case .healthy:
            return .green
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}

struct FullDiagnosticReportView: View {
    let result: SyncDiagnosticResult
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(SyncDiagnosticService.generateDiagnosticReport(result))
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                }
                .padding()
            }
            .navigationTitle(NSLocalizedString("sync.diagnostic.fullReport.title", comment: "Full diagnostic report title"))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(NSLocalizedString("完成", comment: "Done button")) {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

#Preview {
    SyncDiagnosticView(result: SyncDiagnosticResult(
        severity: .warning,
        issues: [.networkUnavailable],
        recommendations: [NSLocalizedString("sync.diagnostic.recommendation.network", comment: "Check network recommendation")],
        timestamp: Date()
    ))
}
