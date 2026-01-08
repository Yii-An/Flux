import SwiftUI

struct LogsView: View {
    @EnvironmentObject var runtimeService: CLIProxyAPIRuntimeService
    @State private var autoScroll = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("日志")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Spacer()
                
                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                
                Button("清空") {
                    // Logs are read-only from service
                }
                .buttonStyle(.bordered)
                .disabled(true)
            }
            .padding(24)
            .padding(.bottom, 0)
            
            Divider()
            
            if runtimeService.logs.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("暂无日志")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("启动 CLIProxyAPI 后将在此显示日志")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(runtimeService.logs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                        .padding(16)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: runtimeService.logs.count) { _, _ in
                        if autoScroll, let lastIndex = runtimeService.logs.indices.last {
                            withAnimation {
                                proxy.scrollTo(lastIndex, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview {
    LogsView()
        .environmentObject(CLIProxyAPIRuntimeService())
}

