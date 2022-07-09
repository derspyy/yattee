import AVKit
#if os(iOS)
    import CoreMotion
#endif
import Defaults
import Siesta
import SwiftUI

struct VideoPlayerView: View {
    #if os(iOS)
        static let hiddenOffset = YatteeApp.isForPreviews ? 0 : max(UIScreen.main.bounds.height, UIScreen.main.bounds.width) + 100
    #endif

    static let defaultAspectRatio = 16 / 9.0
    static var defaultMinimumHeightLeft: Double {
        #if os(macOS)
            300
        #else
            200
        #endif
    }

    @State private var playerSize: CGSize = .zero { didSet {
        withAnimation {
            if playerSize.width > 900 && Defaults[.playerSidebar] == .whenFits {
                sidebarQueue = true
            } else {
                sidebarQueue = false
            }
        }
    }}
    @State private var hoveringPlayer = false
    @State private var fullScreenDetails = false
    @State private var sidebarQueue = false

    @Environment(\.colorScheme) private var colorScheme

    #if os(iOS)
        @Environment(\.verticalSizeClass) private var verticalSizeClass

        @State private var orientation = UIInterfaceOrientation.portrait
        @State private var lastOrientation: UIInterfaceOrientation?
    #elseif os(macOS)
        var mouseLocation: CGPoint { NSEvent.mouseLocation }
    #endif

    #if os(iOS)
        @State private var viewVerticalOffset = Self.hiddenOffset
    #endif

    @EnvironmentObject<AccountsModel> private var accounts
    @EnvironmentObject<NavigationModel> private var navigation
    @EnvironmentObject<PlayerModel> private var player
    @EnvironmentObject<PlayerControlsModel> private var playerControls
    @EnvironmentObject<RecentsModel> private var recents
    @EnvironmentObject<SearchModel> private var search
    @EnvironmentObject<ThumbnailsModel> private var thumbnails

    init() {
        if Defaults[.playerSidebar] == .always {
            sidebarQueue = true
        }
    }

    var body: some View {
        #if DEBUG
            // TODO: remove
            if #available(iOS 15.0, macOS 12.0, *) {
                _ = Self._printChanges()
            }
        #endif

        #if os(macOS)
            return HSplitView {
                content
            }
            .alert(isPresented: $navigation.presentingAlertInVideoPlayer) { navigation.alert }
            .onOpenURL {
                OpenURLHandler(
                    accounts: accounts,
                    navigation: navigation,
                    recents: recents,
                    player: player,
                    search: search
                ).handle($0)
            }
            .frame(minWidth: 950, minHeight: 700)
        #else
            return GeometryReader { geometry in
                HStack(spacing: 0) {
                    content
                        .onAppear {
                            playerSize = geometry.size
                        }
                }
                .ignoresSafeArea(.all, edges: playerEdgesIgnoringSafeArea)
                .onChange(of: geometry.size) { size in
                    self.playerSize = size
                }
                .onChange(of: fullScreenDetails) { value in
                    player.backend.setNeedsDrawing(!value)
                }
                #if os(iOS)
                .onChange(of: player.presentingPlayer) { newValue in
                    if newValue {
                        viewVerticalOffset = 0
                        configureOrientationUpdatesBasedOnAccelerometer()

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak player] in
                            player?.onPresentPlayer?()
                            player?.onPresentPlayer = nil
                        }
                    } else {
                        if Defaults[.lockPortraitWhenBrowsing] {
                            Orientation.lockOrientation(.portrait, andRotateTo: .portrait)
                        } else {
                            Orientation.lockOrientation(.allButUpsideDown)
                        }
                        viewVerticalOffset = Self.hiddenOffset
                    }
                }
                #endif
            }
            #if os(iOS)
            .offset(y: viewVerticalOffset)
            .animation(.easeOut(duration: 0.3), value: viewVerticalOffset)
            .backport
            .persistentSystemOverlays(!fullScreenLayout)
            #endif
        #endif
    }

    var playerEdgesIgnoringSafeArea: Edge.Set {
        #if os(iOS)
            if fullScreenLayout, UIDevice.current.orientation.isLandscape {
                return [.vertical]
            }
        #endif
        return []
    }

    var content: some View {
        Group {
            ZStack(alignment: .bottomLeading) {
                #if os(tvOS)
                    ZStack {
                        playerView

                        tvControls
                    }
                    .ignoresSafeArea(.all, edges: .all)
                    .onMoveCommand { direction in
                        if direction == .up || direction == .down {
                            playerControls.show()
                        }

                        playerControls.resetTimer()

                        guard !playerControls.presentingControls else { return }

                        if direction == .left {
                            player.backend.seek(relative: .secondsInDefaultTimescale(-10))
                        }
                        if direction == .right {
                            player.backend.seek(relative: .secondsInDefaultTimescale(10))
                        }
                    }
                    .onPlayPauseCommand {
                        player.togglePlay()
                    }

                    .onExitCommand {
                        if playerControls.presentingControls {
                            playerControls.hide()
                        } else {
                            player.hide()
                        }
                    }
                #else
                    GeometryReader { geometry in
                        Group {
                            if player.playingInPictureInPicture {
                                pictureInPicturePlaceholder
                            } else {
                                playerView

                                #if !os(tvOS)
                                .modifier(
                                    VideoPlayerSizeModifier(
                                        geometry: geometry,
                                        aspectRatio: player.backend.aspectRatio,
                                        fullScreen: fullScreenLayout
                                    )
                                )
                                .overlay(playerPlaceholder)
                                #endif
                            }
                        }
                        .frame(maxWidth: fullScreenLayout ? .infinity : nil, maxHeight: fullScreenLayout ? .infinity : nil)
                        .onHover { hovering in
                            hoveringPlayer = hovering
                            hovering ? playerControls.show() : playerControls.hide()
                        }
                        #if !os(macOS)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                                .onChanged { value in
                                    guard player.presentingPlayer,
                                          !playerControls.presentingControlsOverlay else { return }

                                    let drag = value.translation.height

                                    guard drag > 0 else { return }

                                    guard drag < 100 else {
                                        player.hide()
                                        return
                                    }

                                    viewVerticalOffset = drag
                                }
                                .onEnded { _ in
                                    if viewVerticalOffset > 100 {
                                        player.backend.setNeedsDrawing(false)
                                        player.hide()
                                    } else {
                                        viewVerticalOffset = 0
                                        player.backend.setNeedsDrawing(true)
                                        player.show()
                                    }
                                }
                        )
                        #else
                                .onAppear(perform: {
                                    NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) {
                                        if !player.currentItem.isNil, hoveringPlayer {
                                            playerControls.resetTimer()
                                        }

                                        return $0
                                    }
                                })
                        #endif

                                .background(Color.black)

                        #if !os(tvOS)
                            if !fullScreenLayout {
                                VStack(spacing: 0) {
                                    #if os(iOS)
                                        VideoDetails(sidebarQueue: sidebarQueue, fullScreen: $fullScreenDetails)
                                            .edgesIgnoringSafeArea(.bottom)
                                    #else
                                        VideoDetails(sidebarQueue: sidebarQueue, fullScreen: $fullScreenDetails)
                                    #endif
                                }
                                #if !os(macOS)
                                .transition(.move(edge: .bottom))
                                #endif
                                .background(colorScheme == .dark ? Color.black : Color.white)
                                .modifier(VideoDetailsPaddingModifier(
                                    playerSize: player.playerSize,
                                    aspectRatio: player.backend.aspectRatio,
                                    fullScreen: fullScreenDetails
                                ))
                            }
                        #endif
                    }
                #endif
            }

            .background(((colorScheme == .dark || fullScreenLayout) ? Color.black : Color.white).edgesIgnoringSafeArea(.all))
            #if os(macOS)
                .frame(minWidth: 650)
            #endif
            if !fullScreenLayout {
                #if os(iOS)
                    if sidebarQueue {
                        PlayerQueueView(sidebarQueue: true, fullScreen: $fullScreenDetails)
                            .frame(maxWidth: 350)
                            .transition(.move(edge: .trailing))
                    }
                #elseif os(macOS)
                    if Defaults[.playerSidebar] != .never {
                        PlayerQueueView(sidebarQueue: true, fullScreen: $fullScreenDetails)
                            .frame(minWidth: 300)
                    }
                #endif
            }
        }
        #if os(iOS)
        .statusBar(hidden: fullScreenLayout)
        #endif
    }

    var playerView: some View {
        ZStack(alignment: .top) {
            Group {
                switch player.activeBackend {
                case .mpv:
                    player.mpvPlayerView
                        .overlay(GeometryReader { proxy in
                            Color.clear
                                .onAppear {
                                    player.playerSize = proxy.size
                                }
                                .onChange(of: proxy.size) { _ in
                                    player.playerSize = proxy.size
                                }
                        })
                case .appleAVPlayer:
                    player.avPlayerView
                    #if os(iOS)
                        .onAppear {
                            player.pipController = .init(playerLayer: player.playerLayerView.playerLayer)
                            let pipDelegate = PiPDelegate()
                            pipDelegate.player = player

                            player.pipDelegate = pipDelegate
                            player.pipController?.delegate = pipDelegate
                            player.playerLayerView.playerLayer.player = player.avPlayerBackend.avPlayer
                        }
                    #endif
                }
            }
            #if os(iOS)
            .padding(.top, player.playingFullScreen && verticalSizeClass == .regular ? 20 : 0)
            #endif

            #if !os(tvOS)
                PlayerGestures()
                PlayerControls(player: player, thumbnails: thumbnails)
                #if os(iOS)
                    .padding(.top, controlsTopPadding)
                    .padding(.bottom, fullScreenLayout ? safeAreaInsets.bottom : 0)
                #endif
            #endif
        }
        #if os(iOS)
        .statusBarHidden(fullScreenLayout)
        #endif
    }

    #if os(iOS)
        var controlsTopPadding: Double {
            guard fullScreenLayout else { return 0 }

            let idiom = UIDevice.current.userInterfaceIdiom
            guard idiom == .pad else { return safeAreaInsets.top }

            return safeAreaInsets.top.isZero ? safeAreaInsets.bottom : safeAreaInsets.top
        }

        var safeAreaInsets: UIEdgeInsets {
            UIApplication.shared.windows.first?.safeAreaInsets ?? .init()
        }
    #endif

    var fullScreenLayout: Bool {
        #if os(iOS)
            player.playingFullScreen || verticalSizeClass == .compact
        #else
            player.playingFullScreen
        #endif
    }

    @ViewBuilder var playerPlaceholder: some View {
        if player.currentItem.isNil {
            ZStack(alignment: .topLeading) {
                HStack {
                    Spacer()
                    VStack {
                        Spacer()
                        VStack(spacing: 10) {
                            #if !os(tvOS)
                                Image(systemName: "ticket")
                                    .font(.system(size: 120))
                            #endif
                        }
                        Spacer()
                    }
                    .foregroundColor(.gray)
                    Spacer()
                }

                #if os(iOS)
                    Button {
                        player.hide()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 40))
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .foregroundColor(.gray)
                #endif
            }
            .background(Color.black)
            .contentShape(Rectangle())
            .frame(width: player.playerSize.width, height: player.playerSize.height)
        }
    }

    var pictureInPicturePlaceholder: some View {
        HStack {
            Spacer()
            VStack {
                Spacer()
                VStack(spacing: 10) {
                    #if !os(tvOS)
                        Image(systemName: "pip")
                            .font(.system(size: 120))
                    #endif

                    Text("Playing in Picture in Picture")
                }
                Spacer()
            }
            .foregroundColor(.gray)
            Spacer()
        }
        .contextMenu {
            Button {
                player.closePiP()
            } label: {
                Label("Exit Picture in Picture", systemImage: "pip.exit")
            }
        }
        .contentShape(Rectangle())
        .frame(width: player.playerSize.width, height: player.playerSize.height)
    }

    #if os(iOS)
        private func configureOrientationUpdatesBasedOnAccelerometer() {
            if OrientationTracker.shared.currentInterfaceOrientation.isLandscape,
               Defaults[.enterFullscreenInLandscape],
               !player.playingFullScreen,
               !player.playingInPictureInPicture
            {
                DispatchQueue.main.async {
                    player.enterFullScreen()
                }
            }

            NotificationCenter.default.addObserver(
                forName: OrientationTracker.deviceOrientationChangedNotification,
                object: nil,
                queue: .main
            ) { _ in
                guard !Defaults[.honorSystemOrientationLock], player.presentingPlayer, !player.playingInPictureInPicture else {
                    return
                }

                let orientation = OrientationTracker.shared.currentInterfaceOrientation

                guard lastOrientation != orientation else {
                    return
                }

                lastOrientation = orientation

                DispatchQueue.main.async {
                    guard Defaults[.enterFullscreenInLandscape] else {
                        return
                    }

                    if orientation.isLandscape {
                        player.enterFullScreen()
                        Orientation.lockOrientation(OrientationTracker.shared.currentInterfaceOrientationMask, andRotateTo: orientation)
                    } else {
                        if !player.playingFullScreen {
                            player.exitFullScreen()
                        } else {
                            Orientation.lockOrientation(.allButUpsideDown, andRotateTo: .portrait)
                        }
                    }
                }
            }
        }
    #endif

    #if os(tvOS)
        var tvControls: some View {
            TVControls(model: playerControls, player: player, thumbnails: thumbnails)
                .onReceive(playerControls.reporter) { _ in
                    playerControls.show()
                    playerControls.resetTimer()
                }
        }
    #endif
}

struct VideoPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        VideoPlayerView()
            .injectFixtureEnvironmentObjects()
    }
}
