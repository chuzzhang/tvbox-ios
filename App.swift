import SwiftUI

@main
struct TVBoxApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.config == nil {
                ConfigView()
            } else {
                HomeView()
            }
        }
        .overlay {
            if state.loading {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    ProgressView("加载配置中…").tint(.white).foregroundColor(.white)
                }
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

struct ConfigView: View {
    @EnvironmentObject var state: AppState
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 40)

            Text("TVBox")
                .font(.system(size: 38, weight: .bold))
            Text("填入接口配置地址，或直接粘贴配置 JSON")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextEditor(text: $input)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: 130)
                .padding(10)
                .background(Color(white: 0.12))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.25)))
                .autocapitalization(.none)
                .disableAutocorrection(true)

            Button {
                state.configText = input.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await state.refreshConfig() }
            } label: {
                Text("载入配置")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if !state.configText.isEmpty {
                Button("沿用上次配置") {
                    Task { await state.refreshConfig() }
                }
                .font(.footnote)
                .foregroundColor(.secondary)
            }

            if let detail = state.lastErrorDetail {
                VStack(alignment: .leading, spacing: 6) {
                    Text("上次失败原因")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ScrollView {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 170)
                    .padding(10)
                    .background(Color(white: 0.12))
                    .cornerRadius(10)
                }
            }

            Spacer()
        }
        .padding(24)
    }
}
