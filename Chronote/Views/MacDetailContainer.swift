//
//  MacDetailContainer.swift
//  Lumory
//
//  Created by Assistant on 6/3/25.
//

import SwiftUI

#if targetEnvironment(macCatalyst)
struct MacDetailContainer<Content: View>: View {
    let content: () -> Content
    
    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }
    
    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: 800)
                .padding(.horizontal, 40)
                .padding(.vertical, 20)
        }
        .background(Color(UIColor.systemBackground))
    }
}
#endif