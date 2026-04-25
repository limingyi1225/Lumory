import SwiftUI

struct BreathingDots: View {
    @State private var isAnimating = false
    let dotCount: Int = 3
    let dotSize: CGFloat = 4
    let color: Color = .blue
    
    var body: some View {
        HStack(spacing: dotSize) {
            ForEach(0..<dotCount, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(isAnimating ? 1.0 : 0.5)
                    .opacity(isAnimating ? 1.0 : 0.5)
                    .animation(
                        Animation.easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: isAnimating
                    )
            }
        }
        .onAppear {
            isAnimating = true
        }
    }
}

struct BreathingDots_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            BreathingDots()
            
            BreathingDots()
                .scaleEffect(2)
            
            HStack {
                Text("Loading")
                BreathingDots()
            }
        }
        .padding()
    }
}
