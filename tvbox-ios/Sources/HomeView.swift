import SwiftUI

struct HomeView: View {
    @EnvironmentObject var state: AppState
    @State private var showConfig = false
    @State private var showSearch = false
    @State private var showFav = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                header

                if let site = state.selectedSite {
                    if site.isCMSRoute {
                        FeedView(site: site)
                            .id(site.key)
                    } else if site.isSpiderRoute {
                        SpiderWebView(site: site)
                            .id(site.key)
                    } else {
                        UnsupportedView(text: "站点类型 \(site.type) 暂不支持")
                    }
                } else {
                    UnsupportedView(text: "配置里没有站点")
                }
            }
            .background(Color(white: 0.06).ignoresSafeArea())
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showConfig) {
            ConfigView().environmentObject(state)
        }
        .sheet(isPresented: $showSearch) {
            SearchView().environmentObject(state)
        }
        .sheet(isPresented: $showFav) {
            LibraryView().environmentObject(state)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(state.sites) { site in
                        Button {
                            state.select(site)
                        } label: {
                            Label("\(site.name)  ·  \(site.routeLabel)",
                                  systemImage: site.key == state.selectedSite?.key ? "checkmark" : "tv")
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tv")
                        Text(state.selectedSite?.name ?? "选择站点")
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.16))
                    .cornerRadius(10)
                }

                Spacer()

                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .semibold))
                }
                Button { showFav = true } label: {
                    Image(systemName: "bookmark").font(.system(size: 17, weight: .semibold))
                }
                Button { showConfig = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 17, weight: .semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .padding(.bottom, 6)
    }
}

// MARK: - CMS 站点内容流
struct FeedView: View {
    @EnvironmentObject var state: AppState
    let site: Site

    /// 全部分类、顶层分类、当前顶层下的子分类
    @State private var allCats: [VCategory] = []
    @State private var roots: [VCategory] = []
    @State private var kids: [VCategory] = []
    @State private var rootId: String = ""
    @State private var current: String = ""
    @State private var items: [VItem] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var err: String? = nil

    private var api: CMSApi {
        CMSApi(base: site.apiURL(base: state.configBase), headers: [:])
    }

    private let cols = [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            if !roots.isEmpty {
                chipRow(roots, selected: rootId, small: false) { c in select(root: c) }
            }
            if !kids.isEmpty {
                chipRow(kids, selected: current, small: true) { c in select(kid: c) }
            }

            if let err {
                DiagnosticView(
                    text: err,
                    onNextSite: { state.switchToNextSite() },
                    onRetry: {
                        self.err = nil
                        Task { await reload() }
                    }
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 18) {
                        ForEach(items) { item in
                            NavigationLink {
                                DetailView(site: site, item: item)
                                    .environmentObject(state)
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
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)

                    if loading {
                        ProgressView().padding(.vertical, 18)
                    }
                }
            }
        }
        .task { await boot() }
    }

    // MARK: - 分类条

    @ViewBuilder
    private func chipRow(_ list: [VCategory], selected: String, small: Bool,
                         tap: @escaping (VCategory) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(list) { c in
                    Button { tap(c) } label: {
                        Text(c.type_name)
                            .font(.system(size: small ? 12 : 13, weight: .medium))
                            .padding(.horizontal, small ? 10 : 12)
                            .padding(.vertical, small ? 6 : 7)
                            .background(selected == c.type_id ? Color.accentColor : Color(white: 0.16))
                            .foregroundColor(selected == c.type_id ? .white : .secondary)
                            .cornerRadius(8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, small ? 4 : 8)
        }
    }

    // MARK: - 加载

    @MainActor
    private func boot() async {
        guard roots.isEmpty else { return }
        loading = true
        do {
            let cats = try await api.categories()
            allCats = cats
            let ids = Set(cats.map(\.type_id))
            let top = cats.filter { c in
                let p = c.type_pid ?? ""
                return p.isEmpty || p == "0" || !ids.contains(p)
            }
            roots = top.isEmpty ? cats : top
            rootId = roots.first?.type_id ?? ""
            kids = children(of: rootId)
            // 顶层分类（分组那一级）本身常常不挂片子，只有子分类有内容。
            // 默认直接落到第一个子分类，否则一进站点就是「该分类没有返回内容」。
            current = kids.first?.type_id ?? rootId
            await reload()
        } catch {
            err = error.localizedDescription
        }
        loading = false
    }

    @MainActor
    private func select(root c: VCategory) {
        guard rootId != c.type_id else { return }
        rootId = c.type_id
        kids = children(of: c.type_id)
        current = kids.first?.type_id ?? c.type_id
        items = []
        page = 1
        err = nil
        Task { await reload() }
    }

    @MainActor
    private func select(kid c: VCategory) {
        guard current != c.type_id else { return }
        current = c.type_id
        items = []
        page = 1
        err = nil
        Task { await reload() }
    }

    /// 顶层 id 为空（XML 源常见，只有一个「全部」）时不该再列一遍子分类
    private func children(of tid: String) -> [VCategory] {
        guard !tid.isEmpty else { return [] }
        return allCats.filter { ($0.type_pid ?? "") == tid && $0.type_id != tid }
    }

    private func nameOf(_ tid: String) -> String {
        allCats.first { $0.type_id == tid }?.type_name ?? tid
    }

    @MainActor
    private func reload() async {
        loading = true
        page = 1
        do {
            let r = try await api.list(tid: current, page: 1)
            items = r.items
            pageCount = r.pagecount
            err = r.items.isEmpty ? "「\(nameOf(current))」没有返回内容" : nil
        } catch {
            err = error.localizedDescription
        }
        loading = false
    }

    @MainActor
    private func loadMore() async {
        loading = true
        let next = page + 1
        do {
            let r = try await api.list(tid: current, page: next)
            if !r.items.isEmpty {
                let existing = Set(items.map(\.vod_id))
                items += r.items.filter { !existing.contains($0.vod_id) }
                page = next
            } else {
                pageCount = page
            }
        } catch {
            pageCount = page
        }
        loading = false
    }
}

// MARK: - 卡片
struct PosterCard: View {
    let item: VItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 用 Color 撑出固定尺寸，图片作为 overlay 填满。
            // 直接给 AsyncImage 加 .frame(height:) 时，scaledToFill 的图片会按自身比例
            // 撑出一个超宽的内容尺寸，LazyVGrid 的格子跟着变宽，相邻卡片就压在一起。
            Color(white: 0.15)
                .frame(height: 156)
                .frame(maxWidth: .infinity)
                .overlay {
                    AsyncImage(url: URL(string: item.vod_pic ?? "")) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        default:
                            Image(systemName: "film")
                                .font(.system(size: 26))
                                .foregroundColor(Color(white: 0.35))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let r = item.vod_remarks, !r.isEmpty {
                        Text(r)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.65))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                            .padding(5)
                    }
                }

            Text(item.vod_name)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

struct UnsupportedView: View {
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundColor(.orange)
            Text(text)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
