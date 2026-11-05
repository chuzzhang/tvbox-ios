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

    @State private var categories: [VCategory] = []
    @State private var current: String = ""
    @State private var items: [VItem] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var loading = false
    @State private var err: String? = nil

    private var api: CMSApi { CMSApi(base: site.api, headers: [:]) }

    private let cols = [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
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
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(current == c.type_id ? Color.accentColor : Color(white: 0.16))
                                    .foregroundColor(current == c.type_id ? .white : .secondary)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            if let err {
                DiagnosticView(text: err)
            } else {
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 14) {
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

    @MainActor
    private func boot() async {
        guard categories.isEmpty else { return }
        loading = true
        do {
            let cats = try await api.categories()
            categories = cats
            current = cats.first?.type_id ?? ""
            await reload()
        } catch {
            err = error.localizedDescription
        }
        loading = false
    }

    @MainActor
    private func reload() async {
        loading = true
        page = 1
        do {
            let r = try await api.list(tid: current, page: 1)
            items = r.items
            pageCount = r.pagecount
            err = r.items.isEmpty ? "该分类没有返回内容" : nil
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
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: URL(string: item.vod_pic ?? "")) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    default:
                        ZStack {
                            Color(white: 0.15)
                            Image(systemName: "film").foregroundColor(Color(white: 0.35))
                        }
                    }
                }
                .frame(height: 156)
                .frame(maxWidth: .infinity)
                .clipped()
                .cornerRadius(8)

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
        }
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
