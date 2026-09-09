// Swift <-> OpenSheetMusicDisplay bridge for the Guitar Notation practice
// pane. Swift calls the four `window.*` functions below via
// `WKWebView.evaluateJavaScript`; this posts back to Swift's
// `WKScriptMessageHandler` ("osmdBridge") on note clicks and load
// completion/failure.
//
// Note correlation: this app's own `MusicXMLParser` walks the same file
// independently to build its `NoteSequence` (for playback/evaluation
// timing) — OSMD has no shared note identity with that. Instead of
// per-pitch identity, notes are correlated by cursor "step" (OSMD's
// cursor advances one voice-entry at a time, so a chord is one step) and
// by timestamp: `stepTimestamps[i]` is the computed time of step `i`,
// matched against `ScoreNote.startTime` on the Swift side. Colors/seeks
// therefore operate at chord/step granularity, not per individual pitch
// within a chord — a deliberate v1 scope limit, not an oversight.

(function () {
    let osmd = null;
    let stepTimestamps = [];        // seconds, per cursor step index
    let stepGraphicalNotes = [];    // GraphicalNote[][], per cursor step index
    let currentStepIndex = -1;

    function post(message) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.osmdBridge) {
            window.webkit.messageHandlers.osmdBridge.postMessage(message);
        }
    }

    window.onerror = function (message, source, lineno, colno) {
        post({ type: "error", message: String(message) + " at " + source + ":" + lineno + ":" + colno });
    };

    function buildIndex(bpm) {
        stepTimestamps = [];
        stepGraphicalNotes = [];
        const cursor = osmd.cursor;
        cursor.reset();
        let index = 0;
        while (!cursor.iterator.EndReached) {
            // OSMD timestamps are in whole-note units (quarter note = 0.25);
            // convert to seconds the same way this app's own MusicXMLParser
            // does (quarterNotes * 60 / bpm), just starting from whole notes.
            const ts = cursor.iterator.currentTimeStamp.RealValue * 4 * (60 / bpm);
            stepTimestamps.push(ts);
            const gnotes = cursor.GNotesUnderCursor();
            stepGraphicalNotes.push(gnotes);
            const stepIndex = index;
            gnotes.forEach(function (gnote) {
                try {
                    const el = gnote.getSVGGElement();
                    if (el) {
                        el.style.cursor = "pointer";
                        el.addEventListener("click", function () {
                            post({ type: "seek", index: stepIndex });
                        });
                    }
                } catch (e) {
                    // Some graphical entries (e.g. rests) may not expose an
                    // SVG element the same way — just leave them unclickable.
                }
            });
            cursor.next();
            index += 1;
        }
        cursor.reset();
        currentStepIndex = 0;
    }

    // `tempoBpm` is supplied by Swift (`NoteSequence.tempo`, read from the
    // same file's `<sound tempo="...">`) rather than derived from OSMD's
    // own `Sheet.DefaultStartTempoInBpm` — that property reflects the
    // raw `<metronome per-minute>` face value, which can be expressed
    // against a different `beat-unit` (e.g. "half note = 70", displayed
    // as such) than the always-quarter-notes-per-minute `<sound tempo>`
    // this app's parser reads. Trusting OSMD's own number silently
    // produced timestamps exactly 2x too large for a real file in this
    // project's test set — verified by comparing against the Swift-side
    // NoteSequence directly, not assumed.
    window.loadMusicXML = function (xmlString, tempoBpm) {
        if (!osmd) {
            osmd = new opensheetmusicdisplay.OpenSheetMusicDisplay("osmd-container", {
                autoResize: true,
                backend: "svg",
                drawTitle: false
            });
        }
        osmd.load(xmlString).then(function () {
            osmd.render();
            buildIndex(tempoBpm > 0 ? tempoBpm : 120);
            osmd.cursor.show();
            post({ type: "ready", noteCount: stepTimestamps.length });
        }).catch(function (err) {
            post({ type: "error", message: String(err) });
        });
    };

    function moveCursorTo(targetIndex) {
        const cursor = osmd.cursor;
        if (targetIndex === currentStepIndex) return;
        const isBackwardJump = targetIndex < currentStepIndex;
        // Small forward steps advance incrementally (cheap, no flicker);
        // anything else resets to the start and replays forward to the
        // target — OSMD's cursor has no random-access API, only
        // reset()/next()/previous().
        if (targetIndex > currentStepIndex && targetIndex - currentStepIndex <= 8) {
            for (let i = currentStepIndex; i < targetIndex; i++) cursor.next();
        } else {
            cursor.reset();
            for (let i = 0; i < targetIndex; i++) cursor.next();
        }
        cursor.update();
        currentStepIndex = targetIndex;
        // The page (not just the cursor) needs to scroll to keep up —
        // OSMD moves the cursor's own position but never scrolls its
        // container, so on a score taller than the view the cursor
        // silently walks off-screen during playback otherwise. Smooth
        // for normal forward progress, instant on a backward jump (loop
        // wrap, rewind) — same convention TabGridView/NotationScoreView's
        // native counterparts already use for their own auto-scroll.
        if (cursor.cursorElement) {
            cursor.cursorElement.scrollIntoView({
                behavior: isBackwardJump ? "auto" : "smooth",
                block: "center"
            });
        }
    }

    window.seekToTime = function (seconds) {
        if (!osmd || stepTimestamps.length === 0) return;
        let lo = 0;
        let hi = stepTimestamps.length - 1;
        while (lo < hi) {
            const mid = (lo + hi) >> 1;
            if (stepTimestamps[mid] < seconds) lo = mid + 1; else hi = mid;
        }
        let target = lo;
        if (target > 0 && Math.abs(stepTimestamps[target - 1] - seconds) < Math.abs(stepTimestamps[target] - seconds)) {
            target -= 1;
        }
        moveCursorTo(target);
    };

    window.colorNote = function (index, colorHex) {
        const gnotes = stepGraphicalNotes[index];
        if (!gnotes) return;
        gnotes.forEach(function (gnote) {
            try { gnote.setColor(colorHex); } catch (e) { /* ignore */ }
        });
    };

    window.resetColors = function () {
        stepGraphicalNotes.forEach(function (gnotes) {
            gnotes.forEach(function (gnote) {
                try { gnote.setColor("#000000"); } catch (e) { /* ignore */ }
            });
        });
    };
})();
