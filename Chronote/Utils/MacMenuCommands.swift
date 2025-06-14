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
        // File Menu - New Window
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) { }
        CommandGroup(replacing: .importExport) { }
        CommandGroup(replacing: .printItem) { }
        
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
    static let diaryEntryDeleted = Notification.Name("diaryEntryDeleted")
    static let minimizeAll = Notification.Name("minimizeAll")
    static let showSettings = Notification.Name("showSettings")
}
#endif