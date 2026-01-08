import SwiftUI

struct SplashView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            #if canImport(UIKit)
            Color(UIColor.systemBackground)
                .ignoresSafeArea()
            #else
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()
            #endif
            
            VStack(spacing: 24) {
                // 图标容器 - 带圆角和阴影
                Image("LumoryIcon")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(
                                colorScheme == .dark 
                                    ? Color.white.opacity(0.15) 
                                    : Color.black.opacity(0.08),
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: colorScheme == .dark 
                            ? Color.black.opacity(0.5) 
                            : Color.black.opacity(0.15),
                        radius: colorScheme == .dark ? 20 : 16,
                        x: 0,
                        y: colorScheme == .dark ? 8 : 6
                    )
                
                // 应用名称
                Text("Lumory")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
            }
            .offset(y: -40)
        }
    }
}

struct SplashView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            SplashView()
                .previewDisplayName("Light Mode")
            SplashView()
                .preferredColorScheme(.dark)
                .previewDisplayName("Dark Mode")
        }
    }
}
