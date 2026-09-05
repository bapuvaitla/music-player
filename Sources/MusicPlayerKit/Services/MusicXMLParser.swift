import Foundation

/// Parses a MusicXML file (`.musicxml`/`.xml`, uncompressed — the
/// zip-compressed `.mxl` variant some tools default to isn't supported
/// yet; export as uncompressed MusicXML instead) into a `NoteSequence`.
/// Used for both guitar tab (via `<notations><technical><string>/<fret>`)
/// and vocal melody — MusicXML represents both the same way underneath,
/// tab just carries extra string/fret annotation on top of the pitch.
///
/// Supports a single part with a single voice, which covers the common
/// case this feature targets (one exported tab, one exported melody line).
/// Doesn't handle `<backup>`/`<forward>` (multi-voice time rewinding) —
/// a multi-voice file will parse but the second voice's timing will be
/// wrong relative to the first.
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
                noteDurationTicks = Double(text)
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
}
