//
//  MacMenuCommands.swift
//  Lumory
//
//  Created by Assistant on 6/3/25.
//

import SwiftUI

#if targetEnvironment(macCatalyst)
struct MacMenuCommands: Commands {
    @FocusedBinding(\.selectedEntry) var selectedEntry
    @FocusedBinding(\.isShowingNewEntry) var isShowingNewEntry
    @FocusedBinding(\.isEditMode) var isEditMode
    @FocusedBinding(\.searchText) var searchText
    @FocusedBinding(\.selectedDate) var selectedDate
    
    var body: some Commands {
        // File Menu
        CommandGroup(replacing: .newItem) {
            Button("New Entry") {
                isShowingNewEntry = true
            }
            .keyboardShortcut("n", modifiers: .command)
            
            Divider()
            
            Button("Import Entries...") {
                NotificationCenter.default.post(name: .showImportView, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            
            Button("Export Entry...") {
                if let entry = selectedEntry {
                    NotificationCenter.default.post(name: .exportEntry, object: entry)
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(selectedEntry == nil)
        }
        
        // Edit Menu
        CommandGroup(after: .pasteboard) {
            Divider()
            
            Button(isEditMode == true ? "Done Editing" : "Edit Entry") {
                isEditMode?.toggle()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(selectedEntry == nil)
            
            Button("Delete Entry") {
                if let entry = selectedEntry {
                    NotificationCenter.default.post(name: .deleteEntry, object: entry)
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selectedEntry == nil)
        }
        
        // View Menu
        CommandMenu("View") {
            Button("Home") {
                NotificationCenter.default.post(name: .navigateToHome, object: nil)
            }
            .keyboardShortcut("1", modifiers: .command)
            
            Button("Calendar") {
                NotificationCenter.default.post(name: .navigateToCalendar, object: nil)
            }
            .keyboardShortcut("2", modifiers: .command)
            
            Button("Mood Report") {
                NotificationCenter.default.post(name: .navigateToMoodReport, object: nil)
            }
            .keyboardShortcut("3", modifiers: .command)
            
            Divider()
            
            Button("Today") {
                selectedDate = Date()
                NotificationCenter.default.post(name: .navigateToToday, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)
            
            Button("Previous Day") {
                if let date = selectedDate {
                    selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: date)
                }
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            
            Button("Next Day") {
                if let date = selectedDate {
                    selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: date)
                }
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            
            Divider()
            
            Button("Search") {
                NotificationCenter.default.post(name: .focusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        
        // Entry Menu
        CommandMenu("Entry") {
            Button("Start Recording") {
                NotificationCenter.default.post(name: .startRecording, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)
            
            Button("Stop Recording") {
                NotificationCenter.default.post(name: .stopRecording, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            
            Divider()
            
            Menu("Set Mood") {
                ForEach(1...5, id: \.self) { mood in
                    Button {
                        NotificationCenter.default.post(name: .setMood, object: mood)
                    } label: {
                        HStack {
                            Circle()
                                .fill(Color.moodSpectrum(for: mood))
                                .frame(width: 12, height: 12)
                            Text("\(mood) - \(moodDescription(for: mood))")
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(mood)")), modifiers: .command)
                }
            }
            
            Divider()
            
            Button("Add Photo...") {
                NotificationCenter.default.post(name: .addPhoto, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        
        // Window Menu
        CommandGroup(after: .windowSize) {
            Button("Minimize All") {
                NotificationCenter.default.post(name: .minimizeAll, object: nil)
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
        }
        
        // App Menu - Settings
        CommandGroup(after: .appSettings) {
            Button("Settings...") {
                NotificationCenter.default.post(name: .showSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
    
    private func moodDescription(for mood: Int) -> String {
        switch mood {
        case 1: return "Very Sad"
        case 2: return "Sad"
        case 3: return "Neutral"
        case 4: return "Happy"
        case 5: return "Very Happy"
        default: return "Unknown"
        }
    }
}

// Focus values for menu commands
struct SelectedEntryKey: FocusedValueKey {
    typealias Value = Binding<DiaryEntry?>
}

struct IsShowingNewEntryKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct IsEditModeKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct SearchTextKey: FocusedValueKey {
    typealias Value = Binding<String>
}

struct SelectedDateKey: FocusedValueKey {
    typealias Value = Binding<Date>
}

extension FocusedValues {
    var selectedEntry: Binding<DiaryEntry?>? {
        get { self[SelectedEntryKey.self] }
        set { self[SelectedEntryKey.self] = newValue }
    }
    
    var isShowingNewEntry: Binding<Bool>? {
        get { self[IsShowingNewEntryKey.self] }
        set { self[IsShowingNewEntryKey.self] = newValue }
    }
    
    var isEditMode: Binding<Bool>? {
        get { self[IsEditModeKey.self] }
        set { self[IsEditModeKey.self] = newValue }
    }
    
    var searchText: Binding<String>? {
        get { self[SearchTextKey.self] }
        set { self[SearchTextKey.self] = newValue }
    }
    
    var selectedDate: Binding<Date>? {
        get { self[SelectedDateKey.self] }
        set { self[SelectedDateKey.self] = newValue }
    }
}

// Notification names for menu actions
extension Notification.Name {
    static let showImportView = Notification.Name("showImportView")
    static let exportEntry = Notification.Name("exportEntry")
    static let deleteEntry = Notification.Name("deleteEntry")
    static let navigateToHome = Notification.Name("navigateToHome")
    static let navigateToCalendar = Notification.Name("navigateToCalendar")
    static let navigateToMoodReport = Notification.Name("navigateToMoodReport")
    static let navigateToToday = Notification.Name("navigateToToday")
    static let focusSearch = Notification.Name("focusSearch")
    static let startRecording = Notification.Name("startRecording")
    static let stopRecording = Notification.Name("stopRecording")
    static let setMood = Notification.Name("setMood")
    static let addPhoto = Notification.Name("addPhoto")
    static let minimizeAll = Notification.Name("minimizeAll")
    static let showSettings = Notification.Name("showSettings")
}
#endif