import Foundation

/// Parses a MusicXML file (`.musicxml`/`.xml`, uncompressed — the
/// zip-compressed `.mxl` variant some tools default to isn't supported
/// yet; export as uncompressed MusicXML instead) into a `NoteSequence`.
/// Used for both guitar tab (via `<notations><technical><string>/<fret>`)
/// and vocal melody — MusicXML represents both the same way underneath,
/// tab just carries extra string/fret annotation on top of the pitch.
///
/// Supports a single part, possibly with multiple voices sharing it via
/// `<backup>`/`<forward>` (e.g. a bass line under a melody) — every
/// voice's notes land in one flat, time-sorted `NoteSequence.notes`, with
/// no separate identity for which voice a note came from.
public enum MusicXMLParser {
    public enum ParseError: LocalizedError {
        case unreadable
        case malformedXML(Error?)

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                return "the file couldn't be read"
            case .malformedXML(let underlying):
                return "not valid XML" + (underlying.map { " (\($0.localizedDescription))" } ?? "")
            }
        }
    }

    public static func parse(fileAt url: URL) throws -> NoteSequence {
        guard let data = try? Data(contentsOf: url) else { throw ParseError.unreadable }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> NoteSequence {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.malformedXML(parser.parserError)
        }
        return NoteSequence(notes: delegate.notes, title: delegate.title, tempo: delegate.tempo, barStartTimes: delegate.barStartTimes, beatsPerBar: delegate.beatsPerBar)
    }

    /// One `<part>` from a multi-part score (e.g. a combined arrangement
    /// with separate vocal, guitar-notation, and guitar-tab staves) — see
    /// `parseAllParts`.
    public struct MusicXMLPart: Sendable {
        /// From `<part-list><score-part><part-name>`, or the part's own
        /// `id` (e.g. "P1") if it has no name.
        public let name: String
        /// True if this part's `<clef><sign>` is `TAB` — i.e. it's a
        /// guitar-tab staff, not standard notation.
        public let isTabPart: Bool
        public let sequence: NoteSequence
    }

    /// Parses every `<part>` in a multi-part MusicXML file separately,
    /// unlike `parse(fileAt:)`/`parse(data:)` which flattens every part's
    /// notes into one `NoteSequence` — appropriate for a single exported
    /// stave (today's tab/vocal/notation imports, which keep using the
    /// single-sequence functions unchanged), but wrong for a combined
    /// score where different parts need to play as distinct, separately
    /// mutable audio tracks (see `MultiTrackPlaybackEngine`).
    public static func parseAllParts(fileAt url: URL) throws -> [MusicXMLPart] {
        guard let data = try? Data(contentsOf: url) else { throw ParseError.unreadable }
        let delegate = MultiPartDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.malformedXML(parser.parserError)
        }
        return delegate.orderedPartIDs.map { id in
            let sequence = NoteSequence(
                notes: delegate.notesByPart[id] ?? [],
                title: delegate.title,
                tempo: delegate.tempo,
                barStartTimes: delegate.barStartTimesByPart[id] ?? [],
                beatsPerBar: delegate.beatsPerBar
            )
            return MusicXMLPart(name: delegate.partNames[id] ?? id, isTabPart: delegate.tabPartIDs.contains(id), sequence: sequence)
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var notes: [ScoreNote] = []
        var title: String?
        var tempo: Double = 120
        var barStartTimes: [TimeInterval] = []
        var beatsPerBar: Int = 4

        private var divisions: Double = 1
        /// Start time (in ticks) of the note/chord group currently being
        /// built — every note sharing a `<chord/>` marker shares this.
        private var groupStartTicks: Double = 0
        /// Where the *next* non-chord note will start.
        private var cursorTicks: Double = 0

        private var currentElementText = ""
        private var isChordNote = false
        private var isRest = false
        private var noteDurationTicks: Double?
        private var pitchStep: String?
        private var pitchAlter = 0
        private var pitchOctave: Int?
        private var stringNumber: Int?
        private var fretNumber: Int?
        /// Set when this note's `<notations>` carries a hammer-on/pull-off/
        /// slide "stop" marker — i.e. it's the destination of a technique
        /// begun on the previous note, not freshly picked.
        private var incomingArticulation: ScoreNote.Articulation?

        /// `<backup>`/`<forward>` rewind or advance the cursor to let a
        /// second voice (e.g. a bass line under a melody) share the same
        /// time range as the first rather than being appended after it.
        /// Tracked separately from `noteDurationTicks` even though both
        /// wrap a `<duration>` element, so a stray value can't leak into
        /// note parsing.
        private enum BackupForwardKind { case backup, forward }
        private var pendingBackupOrForward: BackupForwardKind?
        private var backupForwardDurationTicks: Double?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            currentElementText = ""
            switch elementName {
            case "part":
                // Reset per-part — see the type's doc comment on multi-part
                // limitations.
                cursorTicks = 0
                groupStartTicks = 0
            case "measure":
                barStartTimes.append(ticksToSeconds(cursorTicks))
            case "note":
                isChordNote = false
                isRest = false
                noteDurationTicks = nil
                pitchStep = nil
                pitchAlter = 0
                pitchOctave = nil
                stringNumber = nil
                fretNumber = nil
                incomingArticulation = nil
            case "chord":
                isChordNote = true
            case "rest":
                isRest = true
            case "backup":
                pendingBackupOrForward = .backup
                backupForwardDurationTicks = nil
            case "forward":
                pendingBackupOrForward = .forward
                backupForwardDurationTicks = nil
            case "sound":
                if let tempoString = attributeDict["tempo"], let parsedTempo = Double(tempoString), parsedTempo > 0 {
                    tempo = parsedTempo
                }
            case "hammer-on":
                if attributeDict["type"] == "stop" { incomingArticulation = .hammerOn }
            case "pull-off":
                if attributeDict["type"] == "stop" { incomingArticulation = .pullOff }
            case "slide":
                if attributeDict["type"] == "stop" { incomingArticulation = .slide }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentElementText += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let text = currentElementText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "work-title", "movement-title":
                if title == nil, !text.isEmpty { title = text }
            case "divisions":
                if let value = Double(text), value > 0 { divisions = value }
            case "beats":
                if let value = Int(text), value > 0 { beatsPerBar = value }
            case "duration":
                if pendingBackupOrForward != nil {
                    backupForwardDurationTicks = Double(text)
                } else {
                    noteDurationTicks = Double(text)
                }
            case "backup":
                if let ticks = backupForwardDurationTicks {
                    cursorTicks -= ticks
                    groupStartTicks = cursorTicks
                }
                pendingBackupOrForward = nil
                backupForwardDurationTicks = nil
            case "forward":
                if let ticks = backupForwardDurationTicks {
                    cursorTicks += ticks
                    groupStartTicks = cursorTicks
                }
                pendingBackupOrForward = nil
                backupForwardDurationTicks = nil
            case "step":
                pitchStep = text
            case "alter":
                pitchAlter = Int(text) ?? 0
            case "octave":
                pitchOctave = Int(text)
            case "string":
                stringNumber = Int(text)
            case "fret":
                fretNumber = Int(text)
            case "note":
                finishNote()
            default:
                break
            }
        }

        private func finishNote() {
            defer {
                // Only the group's base note advances the cursor — chord
                // notes share its start time and don't move it further.
                if !isChordNote, let ticks = noteDurationTicks {
                    cursorTicks += ticks
                }
            }

            guard !isRest, let step = pitchStep, let octave = pitchOctave, let ticks = noteDurationTicks else { return }

            let startTicks = isChordNote ? groupStartTicks : cursorTicks
            if !isChordNote { groupStartTicks = startTicks }

            let midiPitch = Self.midiPitch(step: step, alter: pitchAlter, octave: octave)
            notes.append(ScoreNote(
                startTime: ticksToSeconds(startTicks),
                duration: ticksToSeconds(ticks),
                midiPitch: midiPitch,
                string: stringNumber,
                fret: fretNumber,
                incomingArticulation: incomingArticulation
            ))
        }

        private func ticksToSeconds(_ ticks: Double) -> TimeInterval {
            let quarterNotes = ticks / divisions
            return quarterNotes * (60.0 / tempo)
        }

        private static let pitchClassByStep: [String: Int] = [
            "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11
        ]

        private static func midiPitch(step: String, alter: Int, octave: Int) -> Int {
            let pitchClass = pitchClassByStep[step.uppercased()] ?? 0
            return 12 * (octave + 1) + pitchClass + alter
        }
    }

    /// Same tick-tracking/backup-forward/chord logic as `Delegate`, just
    /// fanned out per-part-id instead of into one shared array — kept as
    /// a fully separate class (some duplication) rather than refactoring
    /// `Delegate` to serve both cases, so `parse(fileAt:)`/`parse(data:)`
    /// (used by every existing tab/vocal/notation import) stay completely
    /// untouched by this addition.
    private final class MultiPartDelegate: NSObject, XMLParserDelegate {
        var title: String?
        var tempo: Double = 120
        var beatsPerBar: Int = 4

        var orderedPartIDs: [String] = []
        var partNames: [String: String] = [:]
        var tabPartIDs: Set<String> = []
        var notesByPart: [String: [ScoreNote]] = [:]
        var barStartTimesByPart: [String: [TimeInterval]] = [:]

        private var divisions: Double = 1
        private var currentPartID: String?
        private var groupStartTicks: Double = 0
        private var cursorTicks: Double = 0

        private var currentElementText = ""
        private var isChordNote = false
        private var isRest = false
        private var noteDurationTicks: Double?
        private var pitchStep: String?
        private var pitchAlter = 0
        private var pitchOctave: Int?
        private var stringNumber: Int?
        private var fretNumber: Int?
        private var incomingArticulation: ScoreNote.Articulation?

        private enum BackupForwardKind { case backup, forward }
        private var pendingBackupOrForward: BackupForwardKind?
        private var backupForwardDurationTicks: Double?

        /// `<part-list><score-part id="P1"><part-name>Voice</part-name>`
        /// — captured before any `<part id="P1">` musical content is seen,
        /// so `partNames` is fully populated by the time it's needed.
        private var currentScorePartID: String?
        /// Set while inside a `<clef>` element, to capture its `<sign>`.
        private var isInsideClef = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            currentElementText = ""
            switch elementName {
            case "score-part":
                currentScorePartID = attributeDict["id"]
            case "part":
                guard let id = attributeDict["id"] else { break }
                currentPartID = id
                if !orderedPartIDs.contains(id) {
                    orderedPartIDs.append(id)
                    notesByPart[id] = []
                    barStartTimesByPart[id] = []
                }
                cursorTicks = 0
                groupStartTicks = 0
            case "measure":
                if let id = currentPartID {
                    barStartTimesByPart[id, default: []].append(ticksToSeconds(cursorTicks))
                }
            case "clef":
                isInsideClef = true
            case "note":
                isChordNote = false
                isRest = false
                noteDurationTicks = nil
                pitchStep = nil
                pitchAlter = 0
                pitchOctave = nil
                stringNumber = nil
                fretNumber = nil
                incomingArticulation = nil
            case "chord":
                isChordNote = true
            case "rest":
                isRest = true
            case "backup":
                pendingBackupOrForward = .backup
                backupForwardDurationTicks = nil
            case "forward":
                pendingBackupOrForward = .forward
                backupForwardDurationTicks = nil
            case "sound":
                if let tempoString = attributeDict["tempo"], let parsedTempo = Double(tempoString), parsedTempo > 0 {
                    tempo = parsedTempo
                }
            case "hammer-on":
                if attributeDict["type"] == "stop" { incomingArticulation = .hammerOn }
            case "pull-off":
                if attributeDict["type"] == "stop" { incomingArticulation = .pullOff }
            case "slide":
                if attributeDict["type"] == "stop" { incomingArticulation = .slide }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentElementText += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let text = currentElementText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "work-title", "movement-title":
                if title == nil, !text.isEmpty { title = text }
            case "part-name":
                if let id = currentScorePartID, !text.isEmpty {
                    partNames[id] = text
                }
            case "score-part":
                currentScorePartID = nil
            case "divisions":
                if let value = Double(text), value > 0 { divisions = value }
            case "beats":
                if let value = Int(text), value > 0 { beatsPerBar = value }
            case "sign":
                if isInsideClef, text == "TAB", let id = currentPartID {
                    tabPartIDs.insert(id)
                }
            case "clef":
                isInsideClef = false
            case "duration":
                if pendingBackupOrForward != nil {
                    backupForwardDurationTicks = Double(text)
                } else {
                    noteDurationTicks = Double(text)
                }
            case "backup":
                if let ticks = backupForwardDurationTicks {
                    cursorTicks -= ticks
                    groupStartTicks = cursorTicks
                }
                pendingBackupOrForward = nil
                backupForwardDurationTicks = nil
            case "forward":
                if let ticks = backupForwardDurationTicks {
                    cursorTicks += ticks
                    groupStartTicks = cursorTicks
                }
                pendingBackupOrForward = nil
                backupForwardDurationTicks = nil
            case "step":
                pitchStep = text
            case "alter":
                pitchAlter = Int(text) ?? 0
            case "octave":
                pitchOctave = Int(text)
            case "string":
                stringNumber = Int(text)
            case "fret":
                fretNumber = Int(text)
            case "part":
                currentPartID = nil
            case "note":
                finishNote()
            default:
                break
            }
        }

        private func finishNote() {
            defer {
                if !isChordNote, let ticks = noteDurationTicks {
                    cursorTicks += ticks
                }
            }
            guard let id = currentPartID, !isRest, let step = pitchStep, let octave = pitchOctave, let ticks = noteDurationTicks else { return }

            let startTicks = isChordNote ? groupStartTicks : cursorTicks
            if !isChordNote { groupStartTicks = startTicks }

            let midiPitch = Self.midiPitch(step: step, alter: pitchAlter, octave: octave)
            notesByPart[id, default: []].append(ScoreNote(
                startTime: ticksToSeconds(startTicks),
                duration: ticksToSeconds(ticks),
                midiPitch: midiPitch,
                string: stringNumber,
                fret: fretNumber,
                incomingArticulation: incomingArticulation
            ))
        }

        private func ticksToSeconds(_ ticks: Double) -> TimeInterval {
            let quarterNotes = ticks / divisions
            return quarterNotes * (60.0 / tempo)
        }

        private static let pitchClassByStep: [String: Int] = [
            "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11
        ]

        private static func midiPitch(step: String, alter: Int, octave: Int) -> Int {
            let pitchClass = pitchClassByStep[step.uppercased()] ?? 0
            return 12 * (octave + 1) + pitchClass + alter
        }
    }
}
