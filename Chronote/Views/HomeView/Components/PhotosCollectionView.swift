import SwiftUI
import PhotosUI

struct PhotosCollectionView: View {
    @Binding var selectedImages: [Data]
    @Binding var showImagePicker: Bool
    let maxImages: Int = 9
    
    @State private var showDeleteConfirmation = false
    @State private var imageToDelete: Int?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Label("照片", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("\(selectedImages.count)/\(maxImages)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Photos Grid
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // Add photo button
                    if selectedImages.count < maxImages {
                        AddPhotoButton {
                            showImagePicker = true
                        }
                    }
                    
                    // Selected photos
                    ForEach(selectedImages.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: 80, height: 80)
                            .overlay(
                                Image(systemName: "photo")
                                    .foregroundColor(.secondary)
                            )
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .alert("删除照片", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                if let index = imageToDelete {
                    _ = withAnimation(.easeOut(duration: 0.3)) {
                        selectedImages.remove(at: index)
                    }
                }
            }
        } message: {
            Text("确定要删除这张照片吗？")
        }
    }
}

// MARK: - Supporting Views
private struct AddPhotoButton: View {
    let action: () -> Void
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.blue)
                
                Text("添加")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            .frame(width: 80, height: 80)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5]))
                            .foregroundColor(.blue.opacity(0.3))
                    )
            )
        }
        .buttonStyle(PhotoButtonStyle())
    }
}

// PhotoThumbnail removed for simplicity

private struct PhotoButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

#Preview {
    PhotosCollectionView(
        selectedImages: .constant([]),
        showImagePicker: .constant(false)
    )
    .padding()
}