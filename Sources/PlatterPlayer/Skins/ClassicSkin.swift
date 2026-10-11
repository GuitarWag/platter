import SwiftUI
import PlatterCore

/// A classic .wsz skin. Filled in by the classic skin loader.
struct ClassicSkinView: View {
    let model: PlayerAppModel
    let file: String

    var body: some View {
        PlatterSkinView(model: model)
    }
}
