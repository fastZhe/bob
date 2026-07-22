import AppKit
import ScreenCaptureKit
import CoreGraphics

/// 全屏 / 指定区域截图。需要**屏幕录制权限**。
@MainActor
final class ScreenshotService {

    enum CaptureError: LocalizedError {
        case noDisplay
        case noImage
        case permissionDenied
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "找不到可用显示器"
            case .noImage: return "截屏返回空图像"
            case .permissionDenied: return "没有屏幕录制权限，请到「系统设置 → 隐私与安全性 → 屏幕录制」开启"
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    /// 截取主显示器全屏，返回 NSImage（已包含 retina 2x 像素）。
    /// 优先 ScreenCaptureKit（macOS 14+），失败回退到 CGWindowListCreateImage。
    func captureFullScreen() async throws -> NSImage {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            // 优先抓 NSScreen.main 对应的显示器，避免多屏时抓错屏导致画面放大错位
            let mainDisplayID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = (mainDisplayID.flatMap { id in content.displays.first(where: { $0.displayID == id }) } ?? content.displays.first) else { throw CaptureError.noDisplay }
            return try await captureWithSCStream(display: display)
        } catch let error as CaptureError {
            throw error
        } catch {
            let nsError = error as NSError
            if nsError.domain == "com.apple.screencapture" || nsError.code == -3801 || nsError.code == -3808 {
                throw CaptureError.permissionDenied
            }
            Log.screen.error("ScreenCaptureKit failed (\(nsError.code)), falling back to CGWindowListCreateImage: \(nsError.localizedDescription, privacy: .public)")
            return try captureWithCGWindowList()
        }
    }

    /// SCStream 取一帧（macOS 12.3+ 即可用）
    private func captureWithSCStream(display: SCDisplay) async throws -> NSImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width  = display.width  * 2
        cfg.height = display.height * 2
        cfg.scalesToFit = false

        let capture = StreamCapture()
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: nil)
        try await stream.startCapture()
        defer { Task { try? await stream.stopCapture() } }

        // 等待最多 1.5s 拿一帧
        let deadline = Date().addingTimeInterval(1.5)
        while capture.cgImage == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        guard let cgImage = capture.cgImage else { throw CaptureError.noImage }
        // size 用逻辑点（display.width/height），让 NSImage 作为 2x retina 图，
        // 否则按像素当点画进 view 会放大 2x。
        let size = NSSize(width: display.width, height: display.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    private func captureWithCGWindowList() throws -> NSImage {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            throw CaptureError.permissionDenied
        }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }
}

/// SCStream 的输出回调：第一帧拿到就停
private final class StreamCapture: NSObject, SCStreamOutput {
    let lock = NSLock()
    private var _cgImage: CGImage?

    var cgImage: CGImage? {
        lock.lock(); defer { lock.unlock() }
        return _cgImage
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, _cgImage == nil else { return }
        // 用 IOSurface 拿 CGImage
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        lock.lock()
        _cgImage = cg
        lock.unlock()
    }
}
