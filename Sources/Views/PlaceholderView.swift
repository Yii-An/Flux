import SwiftUI

struct PlaceholderView: View {
    let item: SidebarItem
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: item.systemImage)
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            
            Text(item.title)
                .font(.largeTitle)
                .fontWeight(.semibold)
            
            Text("即将上线")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    PlaceholderView(item: .overview)
}
