import SwiftUI

struct UnreadDivider: View {
    var body: some View {
        HStack {
            VStack { Divider() }
            Text("New stories since last refresh")
                .font(.caption)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            VStack { Divider() }
        }
        .padding(.vertical, 4)
    }
}
