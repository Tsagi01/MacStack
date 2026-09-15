import SwiftUI
import MacStackCore

/// 页面标题。八个页面共用，因此单独抽出来而不是各写一份。
struct PageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}
