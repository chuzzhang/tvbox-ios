import SwiftUI

/// spider 站点（type 3/4）宿主：加载 JS 脚本 → 分类 / 列表 / 详情
struct SpiderWebView: View {
    @EnvironmentObject var state: AppState
    let site: Site

    @State private var spider: JSSpider?
    @State private var initError: String?
    @State private var categories: [VCategory] = []
    @State private var current = ""
    @State private var items: [VItem] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var playing: VDetail?

    private let cols = [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            if let initError {
                UnsupportedView(text: initError)
            } else if spider == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("初始化 JS 引擎…").font(.footnote).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if !categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(categories) { c in
                                Button {
                                    guard current != c.type_id else { return }
                                    current = c.type_id
                                    Task { await reload() }
                                } label: {
                                    Text(c.type_name)
                                        .font(.system(size: 13, weight: .medium))
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(current == c.type_id ? Color.accentColor : Color(white: 0.16))
                                        .foregroundColor(current == c.type_id ? .white : .secondary)
                                        .cornerRadius(8)
                                }
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                }

                ScrollView {
                    LazyVGrid(columns: cols, spacing: 14) {
                        ForEach(items) { item in
                            Button {
                                Task { await openDetail(item) }
                            } label: {
                                PosterCard(item: item)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if item.id == items.last?.id, page < pageCount, !loading {
                                    Task { await loadMore() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                    if loading { ProgressView().padding(.vertical, 18) }
                }
            }
        }
        .task { await boot() }
        .sheet(item: $playing) { d in
            NavigationView {
                DetailContent(site: site,
                              item: VItem(vod_id: d.vod_id, vod_name: d.vod_name,
                                          vod_pic: d.vod_pic, vod_remarks: d.vod_remarks),
                              detail: d)
                    .environmentObject(state)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { playing = nil }
                        }
                    }
            }
            .navigationViewStyle(.stack)
        }
    }

    @MainActor
    private func boot() async {
        guard spider == nil, initError == nil else { return }
        loading = true
        do {
            let r = try await ScriptResolver.resolve(site)
            guard let s = JSSpider(site: site, lib: r.lib, code: r.code) else {
                throw NetError.decode("JSContext 创建失败", r.source)
            }
            spider = s
            let cats = s.home()
            categories = cats
            current = cats.first?.type_id ?? ""
            if let e = s.errorText {
                initError = "脚本异常（\(r.source)）：\(e)"
                loading = false
                return
            }
            if cats.isEmpty {
                initError = "脚本没有返回分类（\(r.source)）"
                loading = false
                return
            }
            await reload()
        } catch {
            initError = error.localizedDescription
        }
        loading = false
    }

    @MainActor
    private func reload() async {
        guard let spider else { return }
        loading = true
        page = 1
        let r = spider.category(tid: current, page: 1)
        items = r.items
        pageCount = r.pageCount
        loading = false
    }

    @MainActor
    private func loadMore() async {
        guard let spider else { return }
        loading = true
        let next = page + 1
        let r = spider.category(tid: current, page: next)
        if !r.items.isEmpty {
            let exist = Set(items.map(\.vod_id))
            items += r.items.filter { !exist.contains($0.vod_id) }
            page = next
        } else {
            pageCount = page
        }
        loading = false
    }

    @MainActor
    private func openDetail(_ item: VItem) async {
        guard let spider else { return }
        let d = spider.detail(id: item.vod_id)
        if let d { playing = d }
    }
}
