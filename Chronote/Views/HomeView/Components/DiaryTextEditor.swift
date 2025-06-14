import SwiftUI

struct DiaryTextEditor: View {
    @Binding var text: String
    @Binding var showEmptyPrompt: Bool
    @FocusState var isTextFieldFocused: Bool
    
    let placeholder: String
    let isCreatingEntry: Bool
    let isTranscribing: Bool
    let transcriptionError: String?
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // 背景
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
            
            // 占位符
            if text.isEmpty && !isTextFieldFocused {
                Text(placeholder)
                    .foregroundColor(.gray)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
            
            // 文本编辑器
            TextEditor(text: $text)
                .focused($isTextFieldFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .disabled(isCreatingEntry)
                .onChange(of: text) { oldValue, newValue in
                    handleTextChange(oldValue: oldValue, newValue: newValue)
                }
            
            // 转录状态指示器
            if isTranscribing {
                TranscriptionIndicator()
                    .position(x: 300, y: 30) // Fixed position for macOS
            }
            
            // 错误提示
            if let error = transcriptionError {
                ErrorBanner(message: error)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(minHeight: 120, maxHeight: 300)
    }
    
    private func handleTextChange(oldValue: String, newValue: String) {
        // 检测清空动作
        if oldValue.count > 0 && newValue.isEmpty {
            withAnimation(.easeInOut(duration: 0.3)) {
                showEmptyPrompt = true
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showEmptyPrompt = false
                }
            }
        }
    }
}

// MARK: - Supporting Views
private struct TranscriptionIndicator: View {
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.blue)
                    .frame(width: 4, height: 4)
                    .scaleEffect(isAnimating ? 1.0 : 0.5)
                    .animation(
                        Animation.easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(index) * 0.2),
                        value: isAnimating
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.05))
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        )
        .onAppear {
            isAnimating = true
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            Text(message)
                .font(.caption)
                .foregroundColor(.primary)
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

#Preview {
    DiaryTextEditor(
        text: .constant(""),
        showEmptyPrompt: .constant(false),
        placeholder: "记录今天的心情...",
        isCreatingEntry: false,
        isTranscribing: false,
        transcriptionError: nil
    )
    .padding()
}