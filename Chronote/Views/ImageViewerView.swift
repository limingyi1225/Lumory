//
//  ImageViewerView.swift
//  Lumory
//
//  Created by Assistant on 6/6/25.
//

import SwiftUI

struct ImageViewerView: View {
    let images: [Data]
    @Binding var selectedIndex: Int
    @Binding var isPresented: Bool
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            // Background
            Color.black
                .ignoresSafeArea()
                .opacity(0.95)
                .onTapGesture {
                    isPresented = false
                }
            
            // Main content
            TabView(selection: $selectedIndex) {
                ForEach(images.indices, id: \.self) { index in
                    Group {
                        #if os(iOS)
                        if let uiImage = UIImage(data: images[index]) {
                            GeometryReader { geometry in
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .scaleEffect(scale)
                                    .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
                                    .gesture(
                                        MagnificationGesture()
                                            .onChanged { value in
                                                scale = value
                                            }
                                            .onEnded { _ in
                                                withAnimation(.spring()) {
                                                    scale = max(1, min(scale, 3))
                                                }
                                            }
                                    )
                                    .simultaneousGesture(
                                        DragGesture()
                                            .onChanged { value in
                                                if scale > 1 {
                                                    dragOffset = value.translation
                                                }
                                            }
                                            .onEnded { _ in
                                                withAnimation(.spring()) {
                                                    offset.width += dragOffset.width
                                                    offset.height += dragOffset.height
                                                    dragOffset = .zero
                                                    
                                                    // Reset if scale is 1
                                                    if scale == 1 {
                                                        offset = .zero
                                                    }
                                                }
                                            }
                                    )
                                    .onTapGesture(count: 2) {
                                        withAnimation(.spring()) {
                                            if scale > 1 {
                                                scale = 1
                                                offset = .zero
                                            } else {
                                                scale = 2
                                            }
                                        }
                                    }
                            }
                        }
                        #else
                        if let nsImage = NSImage(data: images[index]) {
                            GeometryReader { geometry in
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .scaleEffect(scale)
                                    .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
                                    .gesture(
                                        MagnificationGesture()
                                            .onChanged { value in
                                                scale = value
                                            }
                                            .onEnded { _ in
                                                withAnimation(.spring()) {
                                                    scale = max(1, min(scale, 3))
                                                }
                                            }
                                    )
                                    .simultaneousGesture(
                                        DragGesture()
                                            .onChanged { value in
                                                if scale > 1 {
                                                    dragOffset = value.translation
                                                }
                                            }
                                            .onEnded { _ in
                                                withAnimation(.spring()) {
                                                    offset.width += dragOffset.width
                                                    offset.height += dragOffset.height
                                                    dragOffset = .zero
                                                    
                                                    // Reset if scale is 1
                                                    if scale == 1 {
                                                        offset = .zero
                                                    }
                                                }
                                            }
                                    )
                                    .onTapGesture(count: 2) {
                                        withAnimation(.spring()) {
                                            if scale > 1 {
                                                scale = 1
                                                offset = .zero
                                            } else {
                                                scale = 2
                                            }
                                        }
                                    }
                            }
                        }
                        #endif
                    }
                    .tag(index)
                }
            }
            #if os(iOS)
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .always))
            .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
            #else
            .tabViewStyle(.automatic)
            #endif
            
            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.8))
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.3))
                            )
                    }
                    .padding()
                }
                Spacer()
            }
            
            // Image counter
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("\(selectedIndex + 1) / \(images.count)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.3))
                        )
                        .padding()
                }
            }
        }
        .onChange(of: selectedIndex) { _, _ in
            // Reset zoom when changing images
            withAnimation(.spring()) {
                scale = 1
                offset = .zero
                dragOffset = .zero
            }
        }
    }
}

// Preview
#Preview {
    ImageViewerView(
        images: [],
        selectedIndex: .constant(0),
        isPresented: .constant(true)
    )
}