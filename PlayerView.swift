import SwiftUI
import AVFoundation
import AVKit

#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// 播放内核：AVPlayer 吃 HLS/MP4，VLCKit 兜底 MKV/AVI/RMVB/TS
enum PlayerEngine {
    case av
    case vlc
}

final class PlayerModel: ObservableObject {
    @Published var error: String?
    @Published var ready = false
    @Published var engine: PlayerEngine = .av

    private(set) var player: AVPlayer?
    private var statusObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var urlString: String = ""
    private var headers: [String: String] = [:]

    #if canImport(MobileVLCKit)
    private(set) var vlc: VLCMediaPlayer?
    private var vlcDelegate: VLCHolder?
    #endif

    func prepare(_ urlString: String, headers: [String: String] = [:]) {
        self.urlString = urlString
        self.headers = headers
        startAV()
    }

    // MARK: - AVPlayer

    private func startAV() {
        guard let url = URL(string: urlString) else {
            error = "播放地址无效"
            return
        }
        engine = .av
        error = nil
        ready = false

        // 防盗链站需要带 Referer/UA，用私有 options 键注入
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
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
    }

    /// AVPlayer 解不了的容器，直接切 VLCKit 重开，不打扰用户
    private func fallbackToVLC(reason: Error?) {
        #if canImport(MobileVLCKit)
        startVLC()
        #else
        let raw = reason?.localizedDescription ?? "未知错误"
        let low = raw.lowercased()
        if low.contains("unsupported") || low.contains("format") || low.contains("cannot") || low.contains("codec") {
            error = "AVPlayer 不支持该容器（mkv/avi/rmvb/ts）。\n执行 pod install 接入 MobileVLCKit 后自动切换。"
        } else {
            error = raw
        }
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
        player?.pause()
        statusObs?.invalidate()
        statusObs = nil
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
        endObs = nil
        player = nil
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
                    Text(model.engine == .vlc ? "VLC 加载中…" : "加载中…")
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
        .onAppear { model.prepare(urlString) }
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
    override static var layerClass: AnyClass { AVPlayerLayer.self }
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
