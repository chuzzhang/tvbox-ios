import SwiftUI
import AVFoundation
import AVKit

#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// 播放内核：AVPlayer 吃 HLS/MP4，VLCKit 兜底 MKV/AVI/RMVB/TS
enum PlayerEngine: Equatable {
    case av
    case vlc
}

final class PlayerModel: ObservableObject {
    @Published var error: String? = nil
    @Published var ready = false
    @Published var engine: PlayerEngine = .av
    /// 解析阶段的提示（"解析播放地址…"），黑屏前至少让人知道在干什么
    @Published var stage: String? = nil
    /// 地址解析的诊断，出错时一并显示
    @Published var notes: [String] = []

    private(set) var player: AVPlayer?
    private var statusObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var urlString: String = ""
    private var headers: [String: String] = [:]
    /// AVAsset 只弱持 delegate，这里必须强引用，否则代理一释放就黑屏
    private var proxy: HLSProxy?
    private var watchdog: Task<Void, Never>?

    #if canImport(MobileVLCKit)
    private(set) var vlc: VLCMediaPlayer?
    private var vlcDelegate: VLCHolder?
    #endif

    /// 播放前先解析地址：播放页 → 真实流、相对路径补全、补 Referer/UA
    func prepare(_ raw: String, siteBase: String?, parses: [Parse]) {
        stage = "解析播放地址…"
        error = nil
        ready = false
        notes = []

        Task { [weak self] in
            let plan = await PlayResolver.resolve(raw: raw, siteBase: siteBase, parses: parses)
            await MainActor.run {
                guard let self else { return }
                self.stage = nil
                self.notes = plan.notes
                if plan.url.isEmpty {
                    self.error = plan.notes.joined(separator: "\n")
                    return
                }
                self.startAV(plan)
            }
        }
    }

    // MARK: - AVPlayer

    private func startAV(_ plan: PlayResolver.Plan) {
        urlString = plan.url
        headers = plan.headers
        engine = .av
        error = nil
        ready = false

        let asset: AVURLAsset
        if plan.useProxy, let proxied = HLSProxy.proxyURL(plan.url) {
            let hls = HLSProxy(headers: plan.headers)
            proxy?.close()
            proxy = hls
            asset = AVURLAsset(url: proxied)
            asset.resourceLoader.setDelegate(hls, queue: DispatchQueue(label: "osc.tvbox.hlsproxy"))
        } else {
            guard let u = Net.makeURL(plan.url) else {
                error = "播放地址无效"
                return
            }
            asset = AVURLAsset(url: u)
        }

        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        player = p

        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            Task { @MainActor in
                guard let self else { return }
                switch it.status {
                case .readyToPlay:
                    self.ready = true
                    self.player?.play()
                case .failed:
                    self.fallbackToVLC(reason: it.error)
                default:
                    break
                }
            }
        }

        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero)
        }

        armWatchdog()
    }

    /// AVPlayer 遇到「一直 200 但没有可播数据」时不报错，表现就是永久黑屏。
    /// 15 秒没画面就把诊断摆出来，别让人对着黑屏等。
    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, !self.ready, self.error == nil else { return }
                var msg = "15 秒内没有画面。"
                if !self.notes.isEmpty { msg += "\n\n" + self.notes.joined(separator: "\n") }
                msg += "\n\n换一条线路，或确认该源当前是否可用。"
                self.error = msg
            }
        }
    }

    /// AVPlayer 解不了的容器，直接切 VLCKit 重开，不打扰用户
    private func fallbackToVLC(reason: Error?) {
        #if canImport(MobileVLCKit)
        startVLC()
        #else
        let raw = reason?.localizedDescription ?? "未知错误"
        let low = raw.lowercased()
        var msg: String
        if low.contains("unsupported") || low.contains("format") || low.contains("cannot") || low.contains("codec") {
            msg = "AVPlayer 不支持该容器（mkv/avi/rmvb/ts）。\n执行 pod install 接入 MobileVLCKit 后自动切换。"
        } else {
            msg = raw
        }
        if !notes.isEmpty { msg += "\n\n" + notes.joined(separator: "\n") }
        error = msg
        #endif
    }

    // MARK: - VLCKit

    func startVLC() {
        #if canImport(MobileVLCKit)
        teardownAV()
        guard let url = URL(string: urlString) else {
            error = "播放地址无效"
            return
        }
        engine = .vlc
        error = nil
        ready = false

        let p = VLCMediaPlayer()
        let media = VLCMedia(url: url)
        if let ua = headers["User-Agent"] ?? headers["user-agent"], !ua.isEmpty {
            media.addOption(":http-user-agent=\(ua)")
        }
        if let ref = headers["Referer"] ?? headers["referer"], !ref.isEmpty {
            media.addOption(":http-referrer=\(ref)")
        }
        // 弱网缓冲，减少卡顿
        media.addOption(":network-caching=1500")
        p.media = media

        let holder = VLCHolder()
        holder.onState = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .playing, .buffering, .opening:
                    self.ready = true
                case .error:
                    self.error = "VLC 解码失败：\(self.urlString)"
                case .ended:
                    self.vlc?.position = 0
                    self.vlc?.play()
                default:
                    break
                }
            }
        }
        p.delegate = holder
        vlcDelegate = holder
        vlc = p
        #endif
    }

    func attachVLDrawable(_ view: UIView) {
        #if canImport(MobileVLCKit)
        vlc?.drawable = view
        vlc?.play()
        #endif
    }

    // MARK: - 清理

    private func teardownAV() {
        watchdog?.cancel()
        watchdog = nil
        player?.pause()
        statusObs?.invalidate()
        statusObs = nil
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
        endObs = nil
        player = nil
        proxy?.close()
        proxy = nil
    }

    func teardown() {
        teardownAV()
        #if canImport(MobileVLCKit)
        vlc?.stop()
        vlc?.drawable = nil
        vlc = nil
        vlcDelegate = nil
        #endif
    }
}

#if canImport(MobileVLCKit)
final class VLCHolder: NSObject, VLCMediaPlayerDelegate {
    var onState: ((VLCMediaPlayerState) -> Void)?

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let p = aNotification.object as? VLCMediaPlayer else { return }
        onState?(p.state)
    }
}
#endif

// MARK: - 播放页

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let urlString: String
    let title: String
    /// 站点地址，用来补全相对路径、生成 Referer
    var siteBase: String? = nil
    /// 配置里的解析接口，播放页地址靠它换真实流
    var parses: [Parse] = []

    @StateObject private var model = PlayerModel()
    @State private var showUI = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.engine == .av {
                if let p = model.player {
                    AVPlayerLayerView(player: p).ignoresSafeArea()
                }
            } else {
                #if canImport(MobileVLCKit)
                VLCVideoView { view in
                    model.attachVLDrawable(view)
                }
                .ignoresSafeArea()
                #endif
            }

            if !model.ready && model.error == nil {
                VStack(spacing: 10) {
                    ProgressView().tint(.white).scaleEffect(1.4)
                    Text(model.stage ?? (model.engine == .vlc ? "VLC 加载中…" : "加载中…"))
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                }
            }

            if let e = model.error {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34)).foregroundColor(.orange)
                    Text(e)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    HStack(spacing: 12) {
                        #if canImport(MobileVLCKit)
                        if model.engine == .av {
                            Button("用 VLC 重试") { model.startVLC() }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18).padding(.vertical, 9)
                                .background(Color.accentColor).cornerRadius(9)
                                .foregroundColor(.white)
                        }
                        #endif
                        Button("返回") { dismiss() }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            .background(Color(white: 0.2)).cornerRadius(9)
                            .foregroundColor(.white)
                    }
                }
            }

            if showUI {
                VStack {
                    HStack(spacing: 12) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .padding(10)
                                .background(Color.black.opacity(0.45))
                                .clipShape(Circle())
                        }
                        .foregroundColor(.white)

                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Spacer()

                        if model.engine == .av {
                            AirPlayButton()
                                .frame(width: 30, height: 30)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    Spacer()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() } }
        .statusBar(hidden: true)
        .onAppear { model.prepare(urlString, siteBase: siteBase, parses: parses) }
        .onDisappear { model.teardown() }
    }
}

// MARK: - AVPlayerLayer 包装
struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let v = PlayerContainerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - VLC 渲染面
#if canImport(MobileVLCKit)
struct VLCVideoView: UIViewRepresentable {
    let onReady: (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        DispatchQueue.main.async { onReady(v) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif

// MARK: - AirPlay / 投屏（替代原版 DLNA）
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemBlue
        v.prioritizesVideoDevices = true
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
