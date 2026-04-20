import SwiftUI

struct SyncDiagnosticView: View {
    let result: SyncDiagnosticResult?
    @Environment(\.dismiss) private var dismiss
    @State private var showingFullReport = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if let result = result {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: iconForSeverity(result.severity))
                            .font(.system(size: 48))
                            .foregroundColor(colorForSeverity(result.severity))
                        
                        Text("Sync Diagnostic")
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
                                    
                                    Text("No Issues Found")
                                        .font(.headline)
                                    
                                    Text("Your iCloud sync appears to be working correctly.")
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
                                    Text("Issues Found")
                                        .font(.headline)
                                        .foregroundColor(.red)
                                    
                                    ForEach(Array(result.issues.enumerated()), id: \.offset) { index, issue in
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: issue.isCritical ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                                                .foregroundColor(issue.isCritical ? .red : .orange)
                                            
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(issue.description)
                                                    .font(.subheadline)
                                                    .fontWeight(.medium)
                                                
                                                if issue.isCritical {
                                                    Text("Critical Issue")
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
                                        Text("Recommendations")
                                            .font(.headline)
                                            .foregroundColor(.blue)
                                        
                                        ForEach(Array(result.recommendations.enumerated()), id: \.offset) { index, recommendation in
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
                            Text("Generated: \(result.timestamp, style: .date) at \(result.timestamp, style: .time)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top)
                        }
                        .padding()
                    }
                    
                    // Action buttons
                    HStack(spacing: 16) {
                        Button("Show Full Report") {
                            showingFullReport = true
                        }
                        .buttonStyle(.glass)

                        Spacer()

                        Button("Done") {
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
                        
                        Text("No Diagnostic Result")
                            .font(.headline)
                        
                        Text("Please run the diagnostic again.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Button("Close") {
                            dismiss()
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
            .navigationTitle("Sync Diagnostic")
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
        NavigationView {
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
            .navigationTitle("Full Diagnostic Report")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") {
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
        recommendations: ["Check your internet connection"],
        timestamp: Date()
    ))
}
