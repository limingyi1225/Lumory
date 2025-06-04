//
//  MacNewEntryView.swift
//  Lumory
//
//  Created by Assistant on 6/3/25.
//

import SwiftUI
import PhotosUI

#if targetEnvironment(macCatalyst)
struct MacNewEntryView: View {
    @Binding var isPresented: Bool
    @Environment(\.managedObjectContext) private var viewContext
    @State private var content = ""
    @State private var moodValue = 0.5
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedImages: [Data] = []
    @State private var date = Date()
    @State private var isRecording = false
    @StateObject private var audioRecorder = AudioRecorder()
    private let speechRecognizer = AppleSpeechRecognizer()
    @FocusState private var isContentFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    datePickerSection
                    moodSelectorSection
                    contentEditorSection
                    photoPickerSection
                }
                .padding()
            }
        }
        .frame(width: 600, height: 600)
        .background(Color(UIColor.systemBackground))
        .onAppear {
            isContentFocused = true
        }
        .onChange(of: selectedPhotos) { _ in
            Task {
                selectedImages = []
                for item in selectedPhotos {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        selectedImages.append(data)
                    }
                }
            }
        }
    }
    
    private func toggleRecording() {
        if isRecording {
            if let fileName = audioRecorder.stopRecording() {
                // Transcribe the recorded audio
                Task {
                    let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let audioURL = documentsURL.appendingPathComponent(fileName)
                    if let transcribedText = await speechRecognizer.transcribeAudio(fileURL: audioURL, localeIdentifier: "en-US") {
                        content += transcribedText
                    }
                }
            }
        } else {
            audioRecorder.startRecording()
        }
        isRecording.toggle()
    }
    
    private func saveEntry() {
        let newEntry = DiaryEntry(context: viewContext)
        newEntry.id = UUID()
        newEntry.text = content
        newEntry.moodValue = moodValue
        newEntry.date = date
        // Note: Photos would need to be handled differently based on your data model
        // For now, we'll skip photo saving as it's not part of the Core Data model
        
        do {
            try viewContext.save()
            isPresented = false
        } catch {
            print("Error saving entry: \(error)")
        }
    }
    
    @ViewBuilder
    private var headerView: some View {
        HStack {
            Text("New Entry")
                .font(.title2)
                .fontWeight(.semibold)
            
            Spacer()
            
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.escape)
            
            Button("Save") {
                saveEntry()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(content.isEmpty)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(UIColor.systemBackground))
    }
    
    @ViewBuilder
    private var datePickerSection: some View {
        HStack {
            Text("Date:")
                .fontWeight(.medium)
            DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
        }
    }
    
    @ViewBuilder
    private var moodSelectorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mood:")
                .fontWeight(.medium)
            
            HStack(spacing: 20) {
                ForEach(1...5, id: \.self) { value in
                    MoodButton(value: value, selected: Int(moodValue * 4 + 1) == value) {
                        moodValue = Double(value - 1) / 4.0
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var contentEditorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Content:")
                    .fontWeight(.medium)
                
                Spacer()
                
                recordingButton
                
                Text("\(content.count) characters")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            TextEditor(text: $content)
                .font(.system(size: 14))
                .focused($isContentFocused)
                .frame(minHeight: 200)
                .padding(8)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isContentFocused ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .onTextDrop { droppedText in
                    content += droppedText
                }
        }
    }
    
    @ViewBuilder
    private var recordingButton: some View {
        Button(action: toggleRecording) {
            Label(
                isRecording ? "Recording..." : "Record",
                systemImage: isRecording ? "stop.circle.fill" : "mic.circle"
            )
            .foregroundColor(isRecording ? .red : .primary)
        }
        .buttonStyle(.bordered)
        .disabled(isRecording && audioRecorder.isRecording)
    }
    
    @ViewBuilder
    private var photoPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Photos:")
                    .fontWeight(.medium)
                
                Spacer()
                
                PhotosPicker(
                    selection: $selectedPhotos,
                    maxSelectionCount: 5,
                    matching: .images
                ) {
                    Label("Add Photos", systemImage: "photo")
                }
                .buttonStyle(.bordered)
            }
            
            if !selectedImages.isEmpty {
                photoThumbnails
            }
        }
    }
    
    @ViewBuilder
    private var photoThumbnails: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(selectedImages.indices, id: \.self) { index in
                    if let uiImage = UIImage(data: selectedImages[index]) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 100, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                Button(action: {
                                    selectedImages.remove(at: index)
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black.opacity(0.6)))
                                }
                                .buttonStyle(.plain)
                                .padding(4),
                                alignment: .topTrailing
                            )
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

struct MoodButton: View {
    let value: Int
    let selected: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Circle()
                    .fill(Color.moodSpectrum(value: Double(value - 1) / 4.0))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                selected ? Color.accentColor : Color.clear,
                                lineWidth: 3
                            )
                    )
                    .scaleEffect(isHovered ? 1.1 : 1.0)
                
                Text(moodLabel)
                    .font(.caption)
                    .foregroundColor(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
    
    var moodLabel: String {
        switch value {
        case 1: return "Very Sad"
        case 2: return "Sad"
        case 3: return "Neutral"
        case 4: return "Happy"
        case 5: return "Very Happy"
        default: return ""
        }
    }
}
#endif