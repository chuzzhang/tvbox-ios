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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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

                kindSection

                if !state.configBase.isEmpty {
                    Text("配置基准：\(state.configBase)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let report = state.spiderReport {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("顶层 spider")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(report.summary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(report.ok ? .green : .orange)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(Color(white: 0.12))
                    .cornerRadius(10)
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
            }
            .padding(24)
        }
        .onAppear {
            if input.isEmpty { input = state.configText }
        }
    }

    // MARK: - 导入的站点类型

    /// 四个开关决定哪些站点会被导入到列表里。python / jar 现在跑不了，
    /// 默认关，但不禁用开关：开着能看见它们、点进去能看到缺什么，比藏着更好排查。
    private var kindSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("导入的站点类型")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(state.sites.count) / \(state.totalSiteCount) 已导入")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            ForEach(SiteKind.allCases) { k in
                Toggle(isOn: Binding(
                    get: { state.enabledKinds.contains(k) },
                    set: { state.setKind(k, on: $0) }
                )) {
                    HStack(spacing: 6) {
                        Text(k.title)
                            .font(.subheadline)
                        Text("\(state.count(of: k))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        if !k.supported {
                            Text("暂不支持")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.22))
                                .foregroundColor(.orange)
                                .cornerRadius(4)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .tint(.accentColor)

                if !k.supported && state.enabledKinds.contains(k) {
                    Text(k.short + "：打开后这些站点会出现在列表里，点进去会说明缺什么")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if state.filteredOutAll {
                Text("当前勾选下没有站点，至少打开一类")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
        .padding(12)
        .background(Color(white: 0.12))
        .cornerRadius(10)
    }
}
