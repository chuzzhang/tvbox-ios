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

    /// 进度条要的三件事：在放没有、放到哪、总长多少
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    /// 直播流（m3u8 没有 ENDLIST）duration 是 indefinite，进度条只能禁用
    @Published var seekable = false
    /// 应用内音量 0…1。iOS 不允许 App 直接改系统音量，这一层是叠在系统音量之上的系数
    @Published var volume: Double = 1.0
    /// 屏幕亮度 0…1，直接写 UIScreen.brightness；离场要还原，否则退出后屏幕一直是暗的
    @Published var brightness: Double = Double(UIScreen.main.brightness)

    private(set) var player: AVPlayer?
    private var statusObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var urlString: String = ""
    private var headers: [String: String] = [:]
    /// AVAsset 只弱持 delegate，这里必须强引用，否则代理一释放就黑屏
    private var proxy: HLSProxy?
    private var watchdog: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var savedBrightness: CGFloat?

    init() {
        // 音量记住上次的：同一部剧下一集不用每次重调
        let v = UserDefaults.standard.object(forKey: "player.volume") as? Double
        volume = min(1, max(0, v ?? 1.0))
    }

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
        activateAudioSession()
        p.automaticallyWaitsToMinimizeStalling = true
        p.volume = Float(volume)
        player = p
        startTicker()

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

    // MARK: - 播放控制

    func togglePlay() {
        switch engine {
        case .av:
            guard let p = player else { return }
            if p.timeControlStatus == .playing {
                p.pause()
            } else {
                // 暂停后长时间不动、或播到结尾，rate 会是 0，play() 前先归零重来
                if let item = p.currentItem, item.duration.isNumeric,
                   p.currentTime() >= item.duration {
                    p.seek(to: .zero)
                }
                p.play()
            }
            isPlaying = (p.timeControlStatus == .playing)
        case .vlc:
            #if canImport(MobileVLCKit)
            guard let v = vlc else { return }
            if v.isPlaying { v.pause() } else { v.play() }
            isPlaying = v.isPlaying
            #endif
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        switch engine {
        case .av:
            guard let p = player else { return }
            // 容差给 0：HLS 分片边界上不精确 seek 会退回上一个关键帧，表现成"拖了没反应"
            p.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero)
            position = target
        case .vlc:
            #if canImport(MobileVLCKit)
            guard let v = vlc, duration > 0 else { return }
            v.position = Float(target / duration)
            position = target
            #endif
        }
    }

    func seekBy(_ delta: Double) {
        guard seekable else { return }
        seek(to: position + delta)
    }

    // MARK: 音量 / 亮度

    /// 默认的 soloAmbient 会被静音开关掐掉声音，表现就是"音量怎么调都没声"。
    /// 影视类 App 必须显式切到 playback：静音键也出声、锁屏能继续放。
    private func activateAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [])
        try? s.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func setVolume(_ v: Double) {
        volume = min(1, max(0, v))
        player?.volume = Float(volume)
        UserDefaults.standard.set(volume, forKey: "player.volume")
        #if canImport(MobileVLCKit)
        // VLC 的音量是 0…200，跟 AVPlayer 的 0…1 不是一套刻度
        vlc?.audio?.volume = Int32(volume * 200)
        #endif
    }

    func setBrightness(_ v: Double) {
        // 下限留 0.02：调到 0 之后手势还在，但屏幕全黑看不见任何东西
        brightness = min(1, max(0.02, v))
        UIScreen.main.brightness = CGFloat(brightness)
    }

    func captureBrightness() {
        if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
    }

    func restoreBrightness() {
        guard let b = savedBrightness else { return }
        UIScreen.main.brightness = b
        savedBrightness = nil
    }

    /// 0.5 秒采样：进度条、播放/暂停图标都靠它驱动。
    /// 不用 Timer 是因为 Task 跟 model 生命周期绑在一起，teardown 一 cancel 就干净了。
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                await MainActor.run { self?.sample() }
            }
        }
    }

    private func sample() {
        switch engine {
        case .av:
            guard let p = player, let item = p.currentItem else { return }
            isPlaying = (p.timeControlStatus == .playing)
            let d = item.duration.seconds
            if d.isFinite && d > 0 {
                duration = d
                seekable = true
            } else {
                // 直播 m3u8 没有 ENDLIST，duration 是 indefinite
                duration = 0
                seekable = false
            }
            let t = p.currentTime().seconds
            position = t.isFinite ? t : 0
        case .vlc:
            #if canImport(MobileVLCKit)
            guard let v = vlc else { return }
            isPlaying = v.isPlaying
            let len = Double(v.length?.intValue ?? 0) / 1000.0   // VLCTime 是毫秒
            let cur = Double(v.time?.intValue ?? 0) / 1000.0
            duration = len > 1 ? len : 0
            seekable = duration > 0
            position = cur.isFinite && cur > 0 ? cur : 0
            #endif
        }
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
        activateAudioSession()
        p.delegate = holder
        vlcDelegate = holder
        vlc = p
        startTicker()
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
        ticker?.cancel()
        ticker = nil
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
        deactivateAudioSession()
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

    /// 拖动进度条期间先别让采样把滑块位置抢回去
    @State private var dragging = false
    @State private var dragValue: Double = 0
    @State private var hideTask: Task<Void, Never>?

    /// 竖拖 / 横拖的 HUD
    private enum HUD { case volume, brightness, seek }
    private enum DragAxis { case vertical, horizontal }
    @State private var hud: HUD? = nil
    @State private var hudTask: Task<Void, Never>?
    @State private var dragAxis: DragAxis? = nil
    @State private var dragStart: Double = 0
    @State private var seekTarget: Double = 0

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

            // 手势层：点画面开合控制条；左半竖拖调亮度、右半竖拖调音量、横拖调进度。
            // 压在视频上面、控制条下面，所以点按钮、拖滑块不会被它吃掉
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { v in handleDrag(v, size: geo.size) }
                            .onEnded { _ in endDrag() }
                    )
                    .onTapGesture { toggleUI() }
            }
            .ignoresSafeArea()

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
                VStack(spacing: 0) {
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
                    bottomControls
                }
                .transition(.opacity)
            }

            if let h = hud {
                hudView(h)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            model.prepare(urlString, siteBase: siteBase, parses: parses)
            // 看片时别锁屏；亮度先记下来，走的时候还原
            UIApplication.shared.isIdleTimerDisabled = true
            model.captureBrightness()
            kickHide()
        }
        .onDisappear {
            model.teardown()
            hideTask?.cancel()
            hudTask?.cancel()
            model.restoreBrightness()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - 控制条

    private var bottomControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 30) {
                Button { model.seekBy(-10); kickHide() } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 22, weight: .semibold))
                }
                .opacity(model.seekable ? 1 : 0.3)
                .disabled(!model.seekable)

                Button { model.togglePlay(); kickHide() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }

                Button { model.seekBy(10); kickHide() } label: {
                    Image(systemName: "goforward.10").font(.system(size: 22, weight: .semibold))
                }
                .opacity(model.seekable ? 1 : 0.3)
                .disabled(!model.seekable)
            }
            .foregroundColor(.white)

            HStack(spacing: 10) {
                Text(Self.clock(model.position))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 46, alignment: .trailing)

                Slider(value: sliderValue, in: 0...max(model.duration, 0.1)) { editing in
                    if editing {
                        dragValue = model.position
                        dragging = true
                    } else {
                        model.seek(to: dragValue)
                        dragging = false
                    }
                    kickHide()
                }
                .accentColor(.white)
                .disabled(!model.seekable)

                Text(model.seekable ? Self.clock(model.duration) : "直播")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 46, alignment: .leading)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 44)
        .padding(.bottom, 20)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { dragging ? dragValue : model.position },
            set: { dragValue = $0 }
        )
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    // MARK: - 手势：亮度 / 音量 / 进度

    private func handleDrag(_ v: DragGesture.Value, size: CGSize) {
        if dragAxis == nil {
            let dv = abs(v.translation.height), dh = abs(v.translation.width)
            guard max(dv, dh) > 6 else { return }
            if dv >= dh {
                dragAxis = .vertical
                // 左半屏调亮度、右半屏调音量，从按下时那个值开始算增量
                dragStart = v.startLocation.x < size.width / 2 ? model.brightness : model.volume
            } else {
                dragAxis = .horizontal
                dragStart = model.position
                seekTarget = model.position
            }
        }

        switch dragAxis {
        case .vertical?:
            let delta = Double(-v.translation.height) / max(Double(size.height), 1)
            if v.startLocation.x < size.width / 2 {
                model.setBrightness(dragStart + delta)
                showHUD(.brightness)
            } else {
                model.setVolume(dragStart + delta)
                showHUD(.volume)
            }
        case .horizontal?:
            guard model.seekable else { return }
            let span = max(model.duration, 1)
            let moved = Double(v.translation.width / max(size.width, 1)) * span
            seekTarget = min(max(0, dragStart + moved), span)
            showHUD(.seek)
        case .none:
            break
        }
    }

    private func endDrag() {
        if dragAxis == .horizontal, model.seekable, seekTarget > 0 {
            model.seek(to: seekTarget)
        }
        dragAxis = nil
        hideHUDSoon()
    }

    private func showHUD(_ h: HUD) {
        hudTask?.cancel()
        if hud != h { withAnimation(.easeOut(duration: 0.12)) { hud = h } }
    }

    private func hideHUDSoon() {
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            await MainActor.run { withAnimation(.easeIn(duration: 0.2)) { hud = nil } }
        }
    }

    @ViewBuilder
    private func hudView(_ h: HUD) -> some View {
        HStack(spacing: 8) {
            Image(systemName: hudIcon(h)).font(.system(size: 15, weight: .semibold))
            Text(hudLabel(h)).font(.caption.monospacedDigit())
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }

    private func hudIcon(_ h: HUD) -> String {
        switch h {
        case .brightness:
            return model.brightness > 0.66 ? "sun.max.fill"
                 : (model.brightness > 0.33 ? "sun.max" : "sun.min")
        case .volume:
            if model.volume <= 0.001 { return "speaker.slash.fill" }
            return model.volume > 0.66 ? "speaker.wave.3.fill"
                 : (model.volume > 0.33 ? "speaker.wave.2.fill" : "speaker.wave.1.fill")
        case .seek:
            return "arrow.left.and.right"
        }
    }

    private func hudLabel(_ h: HUD) -> String {
        switch h {
        case .brightness: return "亮度 \(Int((model.brightness * 100).rounded()))%"
        case .volume: return "音量 \(Int((model.volume * 100).rounded()))%"
        case .seek: return "\(Self.clock(seekTarget)) / \(Self.clock(model.duration))"
        }
    }

    // MARK: - 控制条显隐

    private func toggleUI() {
        withAnimation(.easeInOut(duration: 0.2)) { showUI.toggle() }
        if showUI { kickHide() } else { hideTask?.cancel() }
    }

    /// 播放中 4 秒后自动收起；暂停时留在屏幕上，不然点一次就没法再点播放
    private func kickHide() {
        hideTask?.cancel()
        guard showUI, model.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) { showUI = false }
            }
        }
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
