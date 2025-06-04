import SwiftUI

// MARK: - Animation Configuration
// Centralized animation settings for consistent performance

struct AnimationConfig {
    // MARK: - Standard Animations
    
    /// Fast response for immediate feedback (0.15s)
    static let fastResponse = Animation.easeOut(duration: 0.15)
    
    /// Standard response for most interactions (0.25s)
    static let standardResponse = Animation.easeInOut(duration: 0.25)
    
    /// Smooth transitions for larger UI changes (0.3s)
    static let smoothTransition = Animation.easeInOut(duration: 0.3)
    
    /// Gentle spring for button presses and small interactions
    static let gentleSpring = Animation.spring(response: 0.3, dampingFraction: 0.75)
    
    /// Bouncy spring for playful interactions
    static let bouncySpring = Animation.spring(response: 0.4, dampingFraction: 0.65)
    
    /// Stiff spring for quick, snappy animations
    static let stiffSpring = Animation.interpolatingSpring(stiffness: 200, damping: 20)
    
    // MARK: - Optimized Replacements
    
    /// Replace complex spring animations with optimized versions
    static func optimizedSpring(mass: Double = 1.0, stiffness: Double = 100, damping: Double = 15) -> Animation {
        // Use interpolatingSpring for better performance
        return .interpolatingSpring(stiffness: stiffness, damping: damping)
    }
    
    /// Replace repetitive animations with cached versions
    static let breathingAnimation = Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true)
    
    // MARK: - Animation Helpers
    
    /// Disable animations temporarily for batch updates
    static func withoutAnimation<Result>(_ body: () throws -> Result) rethrows -> Result {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return try withTransaction(transaction, body)
    }
    
    /// Perform animations with custom timing
    static func withAnimation<Result>(_ animation: Animation?, _ body: () throws -> Result) rethrows -> Result {
        try SwiftUI.withAnimation(animation, body)
    }
}

// MARK: - View Extensions for Performance

extension View {
    /// Apply animation only when value actually changes
    func animationIfChanged<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        self.animation(animation, value: value)
    }
    
    /// Optimize heavy animations by reducing complexity
    func optimizedAnimation<V: Equatable>(_ animation: Animation? = AnimationConfig.standardResponse, value: V) -> some View {
        self.animation(animation, value: value)
    }
    
    /// Disable animations during heavy operations
    func disableAnimationsDuringUpdates() -> some View {
        self.transaction { transaction in
            if ProcessInfo.processInfo.thermalState == .critical {
                transaction.disablesAnimations = true
            }
        }
    }
}

// MARK: - Gesture Performance Helpers

extension DragGesture {
    /// Create optimized drag gesture with debouncing
    static func optimized(minimumDistance: CGFloat = 10) -> DragGesture {
        DragGesture(minimumDistance: minimumDistance)
    }
}

// MARK: - CADisplayLink Frame Rate Helper

extension CAFrameRateRange {
    /// Optimized frame rate for UI updates (30fps for most cases)
    static let uiUpdates = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
    
    /// High performance frame rate for critical animations (60fps)
    static let highPerformance = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
}