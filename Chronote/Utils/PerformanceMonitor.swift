import SwiftUI
import Foundation
import Combine

// MARK: - Performance Monitor for Mac Catalyst

#if targetEnvironment(macCatalyst)
class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()
    
    @Published var isMonitoring = false
    private var startTime: CFAbsoluteTime = 0
    private var frameCount = 0
    private var lastFrameTime: CFAbsoluteTime = 0
    private var timerCancellable: AnyCancellable?
    
    private init() {}
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        startTime = CFAbsoluteTimeGetCurrent()
        frameCount = 0
        lastFrameTime = startTime
        
        // Start timer for frame recording
        timerCancellable = Timer.publish(every: 1/60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.recordFrame()
            }
    }
    
    func stopMonitoring() {
        isMonitoring = false
        timerCancellable?.cancel()
        timerCancellable = nil
    }
    
    func recordFrame() {
        guard isMonitoring else { return }
        frameCount += 1
        lastFrameTime = CFAbsoluteTimeGetCurrent()
    }
    
    var averageFPS: Double {
        guard isMonitoring, frameCount > 0 else { return 0 }
        let elapsed = lastFrameTime - startTime
        return Double(frameCount) / elapsed
    }
    
    deinit {
        timerCancellable?.cancel()
    }
}

// MARK: - Performance Optimized View Modifier

struct PerformanceOptimizedModifier: ViewModifier {
    let identifier: String
    @StateObject private var monitor = PerformanceMonitor.shared
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor.startMonitoring()
            }
            .onDisappear {
                monitor.stopMonitoring()
            }
    }
}

extension View {
    func performanceOptimized(identifier: String = "default") -> some View {
        modifier(PerformanceOptimizedModifier(identifier: identifier))
    }
}

// MARK: - Memory Efficient Image Cache

class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSData>()
    
    private init() {
        cache.countLimit = 50 // Limit to 50 images
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB limit
    }
    
    func setImage(_ data: Data, forKey key: String) {
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }
    
    func image(forKey key: String) -> Data? {
        return cache.object(forKey: key as NSString) as Data?
    }
    
    func removeImage(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }
    
    func clearCache() {
        cache.removeAllObjects()
    }
}

// MARK: - Optimized List Performance

struct OptimizedListModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.plain)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
    }
}

extension View {
    func optimizedForMacCatalyst() -> some View {
        modifier(OptimizedListModifier())
    }
}

// MARK: - Thermal State Monitor

class ThermalStateMonitor: ObservableObject {
    static let shared = ThermalStateMonitor()
    
    @Published var currentState: ProcessInfo.ThermalState = .nominal
    @Published var shouldReduceAnimations = false
    private var observer: NSObjectProtocol?
    
    private init() {
        updateThermalState()
        
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateThermalState()
        }
    }
    
    private func updateThermalState() {
        currentState = ProcessInfo.processInfo.thermalState
        shouldReduceAnimations = currentState == .serious || currentState == .critical
    }
    
    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - Adaptive Animation Configuration

struct AdaptiveAnimationModifier: ViewModifier {
    @StateObject private var thermalMonitor = ThermalStateMonitor.shared
    let animation: Animation
    
    func body(content: Content) -> some View {
        content
            .animation(
                thermalMonitor.shouldReduceAnimations ? nil : animation,
                value: thermalMonitor.currentState
            )
    }
}

extension View {
    func adaptiveAnimation(_ animation: Animation) -> some View {
        modifier(AdaptiveAnimationModifier(animation: animation))
    }
}

#else
// Placeholder implementations for non-Mac Catalyst platforms
class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()
    @Published var isMonitoring = false
    var averageFPS: Double { return 60.0 }
    func startMonitoring() {}
    func stopMonitoring() {}
    func recordFrame() {}
}

extension View {
    func performanceOptimized(identifier: String = "default") -> some View { self }
    func optimizedForMacCatalyst() -> some View { self }
    func adaptiveAnimation(_ animation: Animation) -> some View { self.animation(animation, value: UUID()) }
}

class ImageCache {
    static let shared = ImageCache()
    func setImage(_ data: Data, forKey key: String) {}
    func image(forKey key: String) -> Data? { return nil }
    func removeImage(forKey key: String) {}
    func clearCache() {}
}

class ThermalStateMonitor: ObservableObject {
    static let shared = ThermalStateMonitor()
    @Published var currentState: ProcessInfo.ThermalState = .nominal
    @Published var shouldReduceAnimations = false
}
#endif
