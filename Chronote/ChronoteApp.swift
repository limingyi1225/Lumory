//
//  ChronoteApp.swift
//  Chronote
//
//  Created by Isaac on 5/24/25.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import CoreData
import AVFoundation
import Speech

@main
struct ChronoteApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var importService = CoreDataImportService()
    @AppStorage("appLanguage") private var appLanguage: String = {
        let currentLocale = Locale.current.identifier
        if currentLocale.hasPrefix("zh") {
            return "zh-Hans"
        } else {
            return "en"
        }
    }()
    @State private var showSplash: Bool = true
    init() {
        #if canImport(UIKit)
        UITableView.appearance().separatorStyle = .none
        UITableView.appearance().tableFooterView = UIView()
        #endif
        
        // 执行数据迁移（从 JSON 到 Core Data）
        DataMigrationService.performMigrationIfNeeded()
        requestPermissions()
        
        // Pre-warm animations for better performance
        preWarmAnimations()
    }
    
    // Pre-warm animations for better performance
    private func preWarmAnimations() {
        // Pre-compute common animations to reduce first-time lag
        _ = AnimationConfig.standardResponse
        _ = AnimationConfig.gentleSpring
        _ = AnimationConfig.bouncySpring
        _ = AnimationConfig.breathingAnimation
        
        // Pre-warm CADisplayLink if needed
        #if canImport(UIKit)
        let _ = CAFrameRateRange.uiUpdates
        #endif
    }
    
    // 请求录音权限和语音识别权限
    private func requestPermissions() {
        #if canImport(UIKit)
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: { granted in
                if !granted {
                    print("Microphone permission denied")
                }
            })
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                if !granted {
                    print("Microphone permission denied")
                }
            }
        }
        #else
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            if !granted {
                print("Microphone permission denied")
            }
        }
        #endif

        SFSpeechRecognizer.requestAuthorization { status in
            switch status {
            case .authorized:
                break
            default:
                print("Speech recognition permission status: \(status)")
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                if !showSplash {
                    HomeView()
                        .transition(.opacity)
                        .id(appLanguage) // Force refresh when language changes
                }

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.8), value: showSplash)
            .environment(\.managedObjectContext, persistenceController.container.viewContext)
            .environmentObject(importService)
            .onAppear {
                showSplash = true
                
                #if targetEnvironment(macCatalyst)
                // Configure Mac-specific settings
                DispatchQueue.main.async {
                    UIApplication.shared.configureForMac()
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                        MacToolbarHelper.addToolbarItems(to: windowScene)
                    }
                }
                #endif
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { 
                    showSplash = false
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 700)
        .commands {
            MacMenuCommands()
        }
        #endif
    }
}
