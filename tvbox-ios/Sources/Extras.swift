import SwiftUI

// MARK: - 搜索
struct SearchView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var results: [VItem] = []
    @State private var loading = false
    @State private var msg: String? = nil
    @State private var siteKey: String? = nil

    private var site: Site? {
        let list = state.sites.filter { $0.canSearch }
        if let k = siteKey, let s = list.first(where: { $0.key == k }) { return s }
        return list.first
    }

    private let cols = [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 12)]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("片名 / 演员", text: $keyword)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color(white: 0.15))
                        .cornerRadius(9)
                        .submitLabel(.search)
                        .onSubmit { Task { await run() } }

                    Button("搜索") { Task { await run() } }
                        .font(.subheadline.weight(.semibold))
                        .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                }
                .padding(16)

                if let site {
                    Menu {
                        ForEach(state.sites.filter(\.canSearch)) { s in
                            Button(s.name) { siteKey = s.key }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text("站点：\(site.name)").lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 8)
                }

                if loading {
                    ProgressView().padding(.top, 40)
                    Spacer()
                } else if let msg {
                    UnsupportedView(text: msg)
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, spacing: 14) {
                            ForEach(results) { item in
                                if let site {
                                    NavigationLink {
                                        DetailView(site: site, item: item).environmentObject(state)
                                    } label: {
                                        PosterCard(item: item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
            }
            .background(Color(white: 0.06).ignoresSafeArea())
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @MainActor
    private func run() async {
        guard let site, site.isCMS else {
            msg = "该站不支持搜索或需要 JS 引擎"
            return
        }
        loading = true
        msg = nil
        results = []
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        do {
            let r = try await CMSApi(base: site.api).search(wd: kw)
            results = r
            if r.isEmpty { msg = "没有找到「\(kw)」" }
        } catch {
            msg = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - 收藏 / 历史
struct LibraryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    private let cols = [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 12)]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("收藏").tag(0)
                    Text("历史").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(16)

                let list = tab == 0 ? state.favorites : state.history
                if list.isEmpty {
                    UnsupportedView(text: tab == 0 ? "还没有收藏" : "还没有观看记录")
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, spacing: 14) {
                            ForEach(list) { item in
                                if let site = state.selectedSite {
                                    NavigationLink {
                                        DetailView(site: site, item: item).environmentObject(state)
                                    } label: {
                                        PosterCard(item: item)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    PosterCard(item: item)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
            }
            .background(Color(white: 0.06).ignoresSafeArea())
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
