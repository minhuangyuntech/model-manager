import SwiftUI

extension Provider {
    var color: Color {
        switch self {
        case .ollama: .indigo
        case .lmStudio: .blue
        case .huggingFace: .orange
        case .comfyUI: .purple
        case .custom: .teal
        }
    }
}

struct ModelGallery: View {
    let models: [LocalModel]
    @Binding var selection: LocalModel.ID?
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 245, maximum: 380), spacing: 16)], spacing: 16) {
                ForEach(models) { model in
                    Button { selection = model.id } label: {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Image(systemName: model.source.provider.icon)
                                    .font(.title2).foregroundStyle(model.source.provider.color)
                                    .frame(width: 44, height: 44)
                                    .background(model.source.provider.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                                Spacer()
                                Text(model.format).font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(.quaternary, in: Capsule())
                            }
                            Text(model.name)
                                .font(.headline).lineLimit(2).frame(height: 40, alignment: .topLeading)
                            Text(model.source.provider == .comfyUI ? model.category : model.source.provider.rawValue)
                                .font(.caption).foregroundStyle(model.source.provider.color)
                            Divider()
                            HStack {
                                Label(model.sizeText, systemImage: "internaldrive")
                                Spacer()
                                if selection == model.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(selection == model.id ? model.source.provider.color : Color.primary.opacity(0.07), lineWidth: selection == model.id ? 2 : 1))
                    }.buttonStyle(.plain).help(model.url.path)
                }
            }.padding(20)
        }.background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }
}
