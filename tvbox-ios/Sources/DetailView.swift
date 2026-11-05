import SwiftUI

// MARK: - 详情页（负责取数据）
struct DetailView: View {
    @EnvironmentObject var state: AppState
    let site: Site
    let item: VItem
    let loader: () async throws -> VDetail?

    @State private var detail: VDetail? = nil
    @State private var loading = true
    @State private var err: String? = nil

    init(site: Site, item: VItem) {
        self.site = site
        self.item = item
        // init 里取不到 environmentObject，基准地址从 Store 落盘的那份读
        let base = UserDefaults.standard.string(forKey: "cfg.base") ?? ""
        let api = site.apiURL(base: base)
        self.loader = { try await CMSApi(base: api).detail(id: item.vod_id) }
    }

    init(site: Site, item: VItem, loader: @escaping () async throws -> VDetail?) {
        self.site = site
        self.item = item
        self.loader = loader
    }

    @MainActor
    private func load() async {
        do {
            detail = try await loader()
            if detail == nil { err = "详情为空" }
        } catch {
            err = error.localizedDescription
        }
        loading = false
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err {
                UnsupportedView(text: err)
            } else if let d = detail {
                DetailContent(site: site, item: item, detail: d)
            } else {
                UnsupportedView(text: "没有拿到详情")
            }
        }
        .background(Color(white: 0.06).ignoresSafeArea())
        .navigationTitle(item.vod_name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }
}

// MARK: - 详情页主体（渲染 + 选集播放）
struct DetailContent: View {
    @EnvironmentObject var state: AppState
    let site: Site
    let item: VItem
    let detail: VDetail

    @State private var lineIndex = 0
    @State private var playing: Episode? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                infoBlock

                if let c = detail.vod_content, !c.isEmpty {
                    Text(c.replacingOccurrences(of: "<br>", with: "\n")
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(6)
                }

                if detail.playLines.isEmpty {
                    Text("该资源没有可用播放地址")
                        .font(.footnote).foregroundColor(.secondary)
                } else {
                    linePicker
                    episodeGrid
                }
            }
            .padding(16)
        }
        .background(Color(white: 0.06).ignoresSafeArea())
        .fullScreenCover(item: $playing) { ep in
            PlayerView(urlString: ep.url, title: ep.name)
                .environmentObject(state)
        }
    }

    private var infoBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: URL(string: detail.vod_pic ?? item.vod_pic ?? "")) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color(white: 0.15)
                        Image(systemName: "film").foregroundColor(Color(white: 0.35))
                    }
                }
            }
            .frame(width: 108, height: 156)
            .clipped()
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 8) {
                Text(detail.vod_name).font(.system(size: 17, weight: .bold)).lineLimit(2)

                if let t = detail.type_name, !t.isEmpty {
                    Text(t).font(.caption).foregroundColor(.orange)
                }
                if let r = detail.vod_remarks, !r.isEmpty {
                    Text(r).font(.caption).foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    if let y = detail.vod_year, !y.isEmpty { tag(y) }
                    if let a = detail.vod_area, !a.isEmpty { tag(a) }
                }

                if let act = detail.vod_actor, !act.isEmpty {
                    Text("演员：\(act)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Button {
                    state.toggleFavorite(item)
                } label: {
                    Label(state.isFavorite(item) ? "已收藏" : "收藏",
                          systemImage: state.isFavorite(item) ? "bookmark.fill" : "bookmark")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(white: 0.18))
                        .cornerRadius(7)
                }
                .foregroundColor(.white)
            }
            Spacer(minLength: 0)
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color(white: 0.18))
            .cornerRadius(4)
            .foregroundColor(.secondary)
    }

    private var linePicker: some View {
        let lines = detail.playLines
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<lines.count, id: \.self) { i in
                    Button {
                        lineIndex = i
                    } label: {
                        Text(lines[i].name)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(lineIndex == i ? Color.accentColor : Color(white: 0.16))
                            .foregroundColor(lineIndex == i ? .white : .secondary)
                            .cornerRadius(7)
                    }
                }
            }
        }
    }

    private var episodeGrid: some View {
        let lines = detail.playLines
        let safe = min(lineIndex, max(lines.count - 1, 0))
        let eps = lines.isEmpty ? [] : lines[safe].episodes
        return VStack(alignment: .leading, spacing: 10) {
            Text("选集 · \(eps.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 110), spacing: 8)], spacing: 8) {
                ForEach(eps) { ep in
                    Button {
                        state.markPlayed(item)
                        playing = ep
                    } label: {
                        Text(ep.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color(white: 0.16))
                            .cornerRadius(7)
                            .foregroundColor(.white)
                    }
                }
            }
        }
    }
}
