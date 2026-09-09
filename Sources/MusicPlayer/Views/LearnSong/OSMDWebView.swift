import SwiftUI
import WebKit
import MusicPlayerKit

/// Hosts OpenSheetMusicDisplay (a bundled JS library, see
/// `Resources/OSMDAssets/`) in a `WKWebView` to render real engraved
/// notation for the Guitar Notation practice pane — the first WebKit usage
/// in this app, since there's no native staff-notation renderer (yet; see
/// `GuitarNotationView`'s doc comment).
///
/// Bridges three things across the JS boundary: loading the raw MusicXML,
/// advancing OSMD's cursor to match `currentTime`, and recoloring notes
/// per `evaluation` — plus one JS-to-Swift direction, note clicks, which
/// arrive via `WKScriptMessageHandler` and get translated back to a
/// `TimeInterval` for `onSeek`.
struct OSMDWebView: NSViewRepresentable {
    let musicXMLData: Data
    let currentTime: TimeInterval
    let sequence: NoteSequence
    let evaluation: PerformanceEvaluator.Result?
    let onSeek: (TimeInterval) -> Void

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onSeek: (TimeInterval) -> Void = { _ in }
        var sequence: NoteSequence = NoteSequence(notes: [])
        /// Set once `index.html` finishes loading — calling into
        /// `window.loadMusicXML` before then would silently no-op.
        var pageLoaded = false
        var pendingXMLString: String?
        weak var webView: WKWebView?
        /// Only re-send `loadMusicXML` when the underlying file actually
        /// changes (keyed by byte count — good enough to detect a
        /// Replace…), not on every SwiftUI re-render.
        var loadedByteCount: Int?
        /// Guards against re-pushing every note's color on every
        /// `currentTime` tick (~20/sec during playback) — only when the
        /// evaluation itself actually changes (a new Record/Evaluate pass).
        var lastColoredEvaluation: (noteCount: Int, hitCount: Int)?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "seek":
                guard let index = body["index"] as? Int, index >= 0, index < sequence.notes.count else { return }
                onSeek(sequence.notes[index].startTime)
            case "error":
                print("OSMD load error: \(body["message"] ?? "unknown")")
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            if let xmlString = pendingXMLString {
                loadMusicXML(xmlString, into: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("OSMD page failed to load: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("OSMD page failed to load: \(error.localizedDescription)")
        }

        func loadMusicXML(_ xmlString: String, into webView: WKWebView) {
            guard let encoded = try? JSONEncoder().encode(xmlString), let jsString = String(data: encoded, encoding: .utf8) else { return }
            // Tempo is passed explicitly rather than left for OSMD to
            // derive from the file itself — see bridge.js's `loadMusicXML`
            // doc comment for why that's unreliable (a metronome mark
            // against a non-quarter beat-unit reads as a different number
            // than `<sound tempo>`, which is what `sequence.tempo` here —
            // and this app's own parser's note timings — are always in).
            webView.evaluateJavaScript("window.loadMusicXML && window.loadMusicXML(\(jsString), \(sequence.tempo))")
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onSeek = onSeek
        coordinator.sequence = sequence
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "osmdBridge")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        if let indexURL = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "OSMDAssets") {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSeek = onSeek
        context.coordinator.sequence = sequence

        if context.coordinator.loadedByteCount != musicXMLData.count {
            context.coordinator.loadedByteCount = musicXMLData.count
            let xmlString = String(data: musicXMLData, encoding: .utf8) ?? ""
            if context.coordinator.pageLoaded {
                context.coordinator.loadMusicXML(xmlString, into: webView)
            } else {
                context.coordinator.pendingXMLString = xmlString
            }
        }

        webView.evaluateJavaScript("window.seekToTime && window.seekToTime(\(currentTime))")

        if let evaluation {
            let signature = (evaluation.perNote.count, evaluation.hitCount)
            if context.coordinator.lastColoredEvaluation.map({ $0 != signature }) ?? true {
                context.coordinator.lastColoredEvaluation = signature
                for (index, note) in sequence.notes.enumerated() {
                    guard let match = evaluation.perNote.first(where: { $0.note == note }) else { continue }
                    let color = match.hit ? "#2FA84F" : "#D93B3B"
                    webView.evaluateJavaScript("window.colorNote && window.colorNote(\(index), \"\(color)\")")
                }
            }
        } else if context.coordinator.lastColoredEvaluation != nil {
            context.coordinator.lastColoredEvaluation = nil
            webView.evaluateJavaScript("window.resetColors && window.resetColors()")
        }
    }
}
