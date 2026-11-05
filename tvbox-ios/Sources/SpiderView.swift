import SwiftUI

/// spider 站点（type 3/4）宿主：加载 JS 脚本 → 分类 / 列表 / 详情
struct SpiderWebView: View {
    @EnvironmentObject var state: AppState
    let site: Site

    @State private var spider: JSSpider? = nil
    @State private var initError: String? = nil
    @State private var categories: [VCategory] = []
    @State private var current = ""
    @State private var items: [VItem] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var playing: VDetail? = nil

    private let cols = [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            if let initError {
                DiagnosticView(
                    text: initError,
                    onNextSite: {
                        state.markDead(site.key)
                        if state.switchToNextSite() == nil {
                            // 全被标死了：清空标记，让用户还能自己挑
                            state.deadSiteKeys.removeAll()
                        }
                    },
                    onRetry: {
                        self.initError = nil
                        Task { await boot() }
                    }
                )
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
            // 配置刚导入时 spider 可能还在后台下载，这里补一次
            var report = state.spiderReport
            let base = state.configBase
            if report == nil, let raw = state.config?.spider {
                report = await SpiderStore.shared.report(for: raw, base: base)
            }
            let r = try await ScriptResolver.resolve(site, spider: report, base: base)
            let lib = ScriptResolver.bundledLib()
            let scripts = r.scripts

            // JS 里的同步请求会阻塞线程，整个生命周期放在 JS 专用串行队列上
            let s: JSSpider? = await JSSpider.run { JSSpider(site: site, lib: lib, scripts: scripts) }
            guard let s else {
                throw NetError.decode("JSContext 创建失败", r.diagnostics)
            }
            spider = s
            let cats = await JSSpider.run { s.home() }
            let errText = await JSSpider.run { s.errorText }
            let summary = await JSSpider.run { s.loadSummary }
            categories = cats
            current = cats.first?.type_id ?? ""

            if let e = errText {
                initError = "脚本执行报错\n\n" + e + "\n\n———— 加载过程 ————\n" + r.diagnostics
                loading = false
                return
            }
            if cats.isEmpty {
                initError = "脚本跑起来了，但没拿到分类\n\n"
                    + summary
                    + "\n\n———— 加载过程 ————\n" + r.diagnostics
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
        let tid = current
        let r = await JSSpider.run { spider.category(tid: tid, page: 1) }
        items = r.items
        pageCount = r.pageCount
        loading = false
    }

    @MainActor
    private func loadMore() async {
        guard let spider else { return }
        loading = true
        let next = page + 1
        let tid = current
        let r = await JSSpider.run { spider.category(tid: tid, page: next) }
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
        let id = item.vod_id
        let d = await JSSpider.run { spider.detail(id: id) }
        if let d { playing = d }
    }
}

/// 站点不可用时的诊断面板：内容可选、可复制，直接发出来就能定位
struct DiagnosticView: View {
    let text: String
    /// 站点跑不起来时最有用的一步：直接跳到另一个站点
    var onNextSite: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("加载失败")
                        .font(.subheadline.weight(.semibold))
                }
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if onNextSite != nil || onRetry != nil {
                    HStack(spacing: 10) {
                        if let onRetry {
                            Button(action: onRetry) {
                                Text("重试")
                                    .font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Color(white: 0.18))
                                    .foregroundColor(.primary)
                                    .cornerRadius(8)
                            }
                        }
                        if let onNextSite {
                            Button(action: onNextSite) {
                                Text("换下一个可用站点")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Color.accentColor)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
