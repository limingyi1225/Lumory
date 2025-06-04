//
//  MacDragDropSupport.swift
//  Lumory
//
//  Created by Assistant on 6/3/25.
//

import SwiftUI
import UniformTypeIdentifiers

#if targetEnvironment(macCatalyst)
// Drag and drop support for diary entries
struct DiaryEntryDragItem: Codable, Transferable {
    let id: UUID
    let text: String
    let date: Date
    let moodValue: Double
    
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .diaryEntry)
    }
}

extension UTType {
    static let diaryEntry = UTType(exportedAs: "com.lumory.diary-entry")
}

// Drop delegate for reordering entries
struct DiaryEntryDropDelegate: DropDelegate {
    let entry: DiaryEntry
    @Binding var entries: [DiaryEntry]
    @Binding var draggedEntry: DiaryEntry?
    
    func performDrop(info: DropInfo) -> Bool {
        draggedEntry = nil
        return true
    }
    
    func dropEntered(info: DropInfo) {
        guard let draggedEntry = draggedEntry,
              draggedEntry != entry,
              let fromIndex = entries.firstIndex(of: draggedEntry),
              let toIndex = entries.firstIndex(of: entry) else { return }
        
        withAnimation {
            entries.move(fromOffsets: IndexSet(integer: fromIndex),
                        toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }
}

// Mac-specific text drop support
struct TextDropViewModifier: ViewModifier {
    let onDrop: (String) -> Void
    
    func body(content: Content) -> some View {
        content
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                _ = providers.first?.loadObject(ofClass: String.self) { text, _ in
                    if let text = text {
                        DispatchQueue.main.async {
                            onDrop(text)
                        }
                    }
                }
                return true
            }
    }
}

// Mac-specific image drop support  
struct ImageDropViewModifier: ViewModifier {
    let onDrop: (Data) -> Void
    
    func body(content: Content) -> some View {
        content
            .onDrop(of: [.image], isTargeted: nil) { providers in
                _ = providers.first?.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data = data {
                        DispatchQueue.main.async {
                            onDrop(data)
                        }
                    }
                }
                return true
            }
    }
}

extension View {
    func onTextDrop(perform action: @escaping (String) -> Void) -> some View {
        modifier(TextDropViewModifier(onDrop: action))
    }
    
    func onImageDrop(perform action: @escaping (Data) -> Void) -> some View {
        modifier(ImageDropViewModifier(onDrop: action))
    }
}
#endif