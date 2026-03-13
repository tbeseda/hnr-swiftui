import SwiftUI

struct UnreadDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.hnOrange)
            .frame(height: 2)
            .padding(.vertical, 4)
    }
}
