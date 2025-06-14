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
        request.shouldRefreshRefetchedObjects = false
        request.relationshipKeyPathsForPrefetching = []
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

// MARK: - Optimized Debounced State Updates

@MainActor
class DebouncedState<Value: Equatable & Sendable>: ObservableObject {
    @Published private(set) var value: Value
    private var task: Task<Void, Never>?
    private let duration: TimeInterval

    init(initialValue: Value, debounceFor duration: TimeInterval = 0.3) {
        self.value = initialValue
        self.duration = duration
    }

    func update(_ newValue: Value) {
        // Skip update if value hasn't changed to reduce unnecessary work
        guard newValue != value else { return }

        task?.cancel()
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                if !Task.isCancelled {
                    self.value = newValue
                }
            } catch {
                // Handle cancellation gracefully
            }
        }
    }

    deinit {
        task?.cancel()
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

// MARK: - Mac Catalyst Specific Optimizations

struct MacCatalystOptimizedView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if targetEnvironment(macCatalyst)
        content
            .preferredColorScheme(nil) // Let system handle color scheme
            .dynamicTypeSize(.medium...(.accessibility1)) // Limit dynamic type range for better layout
        #else
        content
        #endif
    }
}

// MARK: - Optimized List Performance

extension View {
    /// Apply Mac Catalyst specific optimizations
    func macCatalystOptimized() -> some View {
        #if targetEnvironment(macCatalyst)
        return self
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            .scrollContentBackground(.hidden)
        #else
        return self
        #endif
    }

    /// Optimize for reduced redraws
    func reduceRedraws<T: Equatable & Hashable>(_ value: T) -> some View {
        self.id(value)
    }
}
