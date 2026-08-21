import AppKit
import AVFoundation
import ImageIO
import OSLog
import QuartzCore

enum ClipboardFeedbackKind: Hashable {
    case copyOrCut
    case paste

    var animationResourceName: String {
        switch self {
        case .copyOrCut: "clipboard-copy-cut"
        case .paste: "clipboard-paste"
        }
    }
}

@MainActor
final class FinderFeedbackPresenter {
    private let defaults: UserDefaults
    private let clipboardPanel: ClipboardFeedbackPanel

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        clipboardPanel = ClipboardFeedbackPanel(bundle: bundle)
    }

    var pasteSoundEnabled: Bool {
        defaults.object(forKey: AppPreferenceKey.pasteSoundEnabled) == nil
            ? true
            : defaults.bool(forKey: AppPreferenceKey.pasteSoundEnabled)
    }

    func show(_ event: FinderFeedbackEvent) {
        switch event {
        case .copied, .cutArmed:
            clipboardPanel.show(.copyOrCut)
        case .pasteSubmitted:
            clipboardPanel.show(.paste, playSound: pasteSoundEnabled)
        }
    }

    func setPasteSoundEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: AppPreferenceKey.pasteSoundEnabled)
        if !enabled {
            clipboardPanel.stopSound()
        }
    }

    func stop() {
        clipboardPanel.stop()
    }
}

@MainActor
final class ClipboardFeedbackPanel {
    private static let panelSize = CGSize(width: 148, height: 148)
    private static let logger = Logger(
        subsystem: "com.sunkanwei.Meno",
        category: "Feedback"
    )

    private let panel: NSPanel
    private let contentView: NSView
    private let animationView: AnimatedPNGView
    private var animations: [ClipboardFeedbackKind: AnimatedPNG] = [:]
    private var pasteSoundPlayer: AVAudioPlayer?
    private var hideWorkItem: DispatchWorkItem?

    init(bundle: Bundle = .main) {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentView = NSView(frame: CGRect(origin: .zero, size: Self.panelSize))
        animationView = AnimatedPNGView(
            frame: CGRect(x: 6, y: 6, width: 136, height: 136)
        )

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.addSubview(animationView)

        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.contentView = contentView

        for kind in [ClipboardFeedbackKind.copyOrCut, .paste] {
            guard let animation = AnimatedPNG(
                resourceName: kind.animationResourceName,
                bundle: bundle
            ) else {
                Self.logger.error(
                    "Clipboard feedback animation is unavailable: \(kind.animationResourceName, privacy: .public)"
                )
                continue
            }
            animations[kind] = animation
        }

        preparePasteSound(bundle: bundle)
    }

    func show(_ kind: ClipboardFeedbackKind, playSound: Bool = true) {
        hideWorkItem?.cancel()
        pasteSoundPlayer?.stop()
        positionPanel()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animation = animations[kind]
        if let animation {
            animationView.show(animation, reduceMotion: reduceMotion)
        } else {
            animationView.stop()
        }
        let duration = reduceMotion ? 0.8 : animation?.duration ?? 0.8

        if reduceMotion {
            contentView.layer?.removeAnimation(forKey: "visibility")
            contentView.layer?.opacity = 1
        } else {
            animateVisibility(duration: duration)
        }

        if kind == .paste, playSound {
            pasteSoundPlayer?.currentTime = 0
            pasteSoundPlayer?.play()
        }

        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    func stop() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        pasteSoundPlayer?.stop()
        contentView.layer?.removeAnimation(forKey: "visibility")
        animationView.stop()
        panel.orderOut(nil)
    }

    func stopSound() {
        pasteSoundPlayer?.stop()
    }

    private func preparePasteSound(bundle: Bundle) {
        guard let url = bundle.url(
            forResource: "clipboard-paste-success",
            withExtension: "mp3"
        ) else {
            Self.logger.error("Clipboard paste feedback sound is missing")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            pasteSoundPlayer = player
        } catch {
            Self.logger.error(
                "Unable to prepare clipboard paste feedback sound: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func animateVisibility(duration: TimeInterval) {
        guard let layer = contentView.layer else { return }
        layer.removeAnimation(forKey: "visibility")
        layer.opacity = 0

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0]
        animation.keyTimes = [0, 0.05, 0.9, 1]
        animation.duration = duration
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeIn),
        ]
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "visibility")
    }

    private func positionPanel() {
        guard let screen = screenContainingMouse() ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        let frame = screen.frame
        panel.setFrame(
            CGRect(
                x: frame.midX - Self.panelSize.width / 2,
                y: frame.midY - Self.panelSize.height / 2,
                width: Self.panelSize.width,
                height: Self.panelSize.height
            ),
            display: panel.isVisible
        )
    }

    private func screenContainingMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }
}

private struct AnimatedPNG {
    let frames: [CGImage]
    let duration: TimeInterval
    let keyTimes: [NSNumber]

    init?(
        resourceName: String,
        bundle: Bundle
    ) {
        guard let url = bundle.url(forResource: resourceName, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var decodedFrames: [CGImage] = []
        var frameDurations: [TimeInterval] = []
        decodedFrames.reserveCapacity(count)
        frameDurations.reserveCapacity(count)
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                return nil
            }
            decodedFrames.append(frame)
            frameDurations.append(Self.frameDuration(source: source, index: index))
        }

        let totalDuration = frameDurations.reduce(0, +)
        var elapsed: TimeInterval = 0
        let resolvedKeyTimes = frameDurations.map { frameDuration in
            defer { elapsed += frameDuration }
            return NSNumber(value: elapsed / totalDuration)
        }
        frames = decodedFrames
        duration = totalDuration
        keyTimes = resolvedKeyTimes
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        let fallbackDuration = 1.0 / 30.0
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil),
              let pngProperties = (properties as NSDictionary)[kCGImagePropertyPNGDictionary]
                as? NSDictionary else {
            return fallbackDuration
        }
        for key in [
            kCGImagePropertyAPNGUnclampedDelayTime,
            kCGImagePropertyAPNGDelayTime,
        ] {
            if let value = pngProperties[key] as? NSNumber,
               value.doubleValue > 0 {
                return value.doubleValue
            }
        }
        return fallbackDuration
    }
}

private final class AnimatedPNGView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .linear
        layer?.magnificationFilter = .linear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ animation: AnimatedPNG, reduceMotion: Bool) {
        guard let layer, let finalFrame = animation.frames.last else { return }
        layer.removeAnimation(forKey: "frames")
        layer.contents = finalFrame

        guard !reduceMotion, animation.frames.count > 1 else { return }

        let frameAnimation = CAKeyframeAnimation(keyPath: "contents")
        frameAnimation.values = animation.frames
        frameAnimation.keyTimes = animation.keyTimes
        frameAnimation.duration = animation.duration
        frameAnimation.calculationMode = .discrete
        frameAnimation.fillMode = .both
        frameAnimation.isRemovedOnCompletion = false
        layer.add(frameAnimation, forKey: "frames")
    }

    func stop() {
        layer?.removeAnimation(forKey: "frames")
        layer?.contents = nil
    }
}
