import SwiftUI

struct DiaryEntryRow: View {
    let entry: DiaryEntry
    @State private var imageData: Data?
    @AppStorage("appLanguage") private var appLanguage: String = "en"
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Date badge
            dateBadge
            
            // Content
            VStack(alignment: .leading, spacing: 8) {
                // Summary or text preview - optimized for Mac Catalyst
                Text(entry.displayText)
                    .font(.system(size: PlatformInfo.isMacCatalyst ? 15 : 16, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                // Metadata row
                HStack(spacing: 12) {
                    // Mood indicator - show if mood value is not default (0.5)
                    if entry.moodValue != 0.5 {
                        MoodIndicator(value: entry.moodValue)
                    }
                    
                    // Audio indicator
                    if entry.audioFileName != nil {
                        Label("", systemImage: "waveform")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    
                    // Image indicator
                    if !entry.imageFileNameArray.isEmpty {
                        Label("\(entry.imageFileNameArray.count)", systemImage: "photo")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    
                    Spacer()
                    
                    // Time
                    Text(timeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Thumbnail
            if let imageData = imageData {
                #if canImport(UIKit)
                if let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipped()
                        .cornerRadius(8)
                }
                #else
                // For macOS, use NSImage
                if let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipped()
                        .cornerRadius(8)
                }
                #endif
            } else {
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.1))
        )
        .onAppear {
            loadThumbnail()
        }
    }
    
    private var dateBadge: some View {
        VStack(spacing: 2) {
            Text(dayString)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.primary)
            
            Text(monthString)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(width: 50)
    }
    
    // Optimized date formatters - use static instances to avoid repeated creation
    private var dayString: String {
        dayFormatter(for: appLanguage).string(from: entry.wrappedDate)
    }

    private var monthString: String {
        monthFormatter(for: appLanguage).string(from: entry.wrappedDate)
    }

    private var timeString: String {
        timeFormatter(for: appLanguage).string(from: entry.wrappedDate)
    }

    // Dynamic formatters that respond to language changes
    private func dayFormatter(for language: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: language)
        f.dateFormat = "dd"
        return f
    }

    private func monthFormatter(for language: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: language)
        f.dateFormat = "MMM"
        return f
    }

    private func timeFormatter(for language: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: language)
        f.timeStyle = .short
        return f
    }
    
    private func loadThumbnail() {
        guard imageData == nil,
              let firstImageName = entry.imageFileNameArray.first else { return }

        // Use utility queue for better performance on Mac Catalyst
        Task.detached(priority: .utility) {
            if let data = await entry.loadImageData(fileName: firstImageName) {
                await MainActor.run {
                    self.imageData = data
                }
            }
        }
    }
}

// MARK: - Supporting Views
struct MoodIndicator: View {
    let value: Double
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.moodSpectrum(value: value))
                .frame(width: 8, height: 8)
            
            Text(moodText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var moodText: String {
        switch value {
        case 0..<0.2:
            return "很差"
        case 0.2..<0.4:
            return "较差"
        case 0.4..<0.6:
            return "一般"
        case 0.6..<0.8:
            return "不错"
        case 0.8...1.0:
            return "很好"
        default:
            return "一般"
        }
    }
}

#Preview {
    DiaryEntryRow(entry: {
        let context = PersistenceController.shared.container.viewContext
        let entry = DiaryEntry(context: context)
        entry.id = UUID()
        entry.date = Date()
        entry.text = "今天是个好天气，心情特别愉快。和朋友一起吃了午饭，聊了很多有趣的话题。"
        entry.summary = "愉快的一天"
        entry.moodValue = 0.8
        // hasMoodAnalysis property has been removed
        return entry
    }())
    .padding()
}