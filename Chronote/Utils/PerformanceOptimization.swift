import SwiftUI
import CoreData

// MARK: - Core Data Performance Optimizations

// MARK: - Fetch Request Helper
struct FetchRequestOptimizer {
    /// Configure fetch request for optimal performance
    static func configure<T: NSFetchRequestResult>(_ request: NSFetchRequest<T>, batchSize: Int = 20) -> NSFetchRequest<T> {
        request.fetchBatchSize = batchSize
        request.returnsObjectsAsFaults = true
        request.includesPendingChanges = false
        return request
    }
}

// MARK: - View Performance Helpers

extension View {
    /// Optimize list performance by reducing redraws
    func optimizedList() -> some View {
        self
            .listStyle(.plain)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
    }
    
    /// Defer heavy computations until after render
    func deferredComputation<T>(_ computation: @escaping () -> T, completion: @escaping (T) -> Void) -> some View {
        self.task(priority: .utility) {
            let result = computation()
            await MainActor.run {
                completion(result)
            }
        }
    }
}

// MARK: - Debounced State Updates

@MainActor
class DebouncedState<Value>: ObservableObject {
    @Published private(set) var value: Value
    private var task: Task<Void, Never>?
    private let duration: TimeInterval
    
    init(initialValue: Value, debounceFor duration: TimeInterval = 0.3) {
        self.value = initialValue
        self.duration = duration
    }
    
    func update(_ newValue: Value) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled {
                self.value = newValue
            }
        }
    }
}

// MARK: - Batch Update Helper

extension NSManagedObjectContext {
    /// Perform batch updates with animation disabled for better performance
    func performBatchUpdates(_ updates: @escaping () throws -> Void) async throws {
        try await self.perform {
            try AnimationConfig.withoutAnimation {
                try updates()
            }
            if self.hasChanges {
                try self.save()
            }
        }
    }
}

// MARK: - Memory-Efficient Image Loading

struct OptimizedImage: View {
    let systemName: String
    let size: CGFloat
    
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size))
            .symbolRenderingMode(.hierarchical)
            .drawingGroup() // Flatten view hierarchy for better performance
    }
}

// MARK: - Lazy Loading Helper

struct LazyLoadView<Content: View>: View {
    let content: () -> Content
    @State private var hasAppeared = false
    
    var body: some View {
        Group {
            if hasAppeared {
                content()
            } else {
                Color.clear
                    .onAppear {
                        hasAppeared = true
                    }
            }
        }
    }
}