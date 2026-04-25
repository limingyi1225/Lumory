import SwiftUI

// MARK: - Animation Configuration
// Centralized animation settings for consistent performance

struct AnimationConfig {
    // MARK: - Standard Animations
    
    /// Fast response for immediate feedback - optimized for Mac Catalyst
    static let fastResponse = Animation.easeOut(duration: 0.1)

    /// Standard response for most interactions - optimized for Mac Catalyst
    static let standardResponse = Animation.easeInOut(duration: 0.15)

    /// Smooth transitions for larger UI changes - optimized for Mac Catalyst
    static let smoothTransition = Animation.easeInOut(duration: 0.2)
    
    /// Gentle spring for button presses and small interactions - Mac optimized
    static let gentleSpring = Animation.spring(
        response: 0.2,
        dampingFraction: 0.85
    )

    /// Stiff spring for quick, snappy animations - Mac optimized
    static let stiffSpring = Animation.interpolatingSpring(
        stiffness: 300,
        damping: 30
    )
}

// MARK: - CADisplayLink Frame Rate Helper

extension CAFrameRateRange {
    /// Optimized frame rate for UI updates (30fps for most cases)
    static let uiUpdates = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
}
