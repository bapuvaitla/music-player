import Foundation

/// Menu-bar commands live at the App/Scene level and have no access to a
/// window's local `@State` (which track is selected, which popover is
/// open, etc.), so a command that needs one posts a notification here and
/// the view that owns the relevant state responds to it — the same
/// pattern already used for the "locate playing track" scroll trigger,
/// just generalized. Keyboard shortcuts for these live on the menu items
/// themselves (see `MusicPlayerApp.commands`), not duplicated on the view
/// side — two registrations of the same shortcut is exactly the bug that
/// made Cmd+I intermittently show a stale/empty edit sheet before.
extension Notification.Name {
    static let requestAddMusic = Notification.Name("MusicPlayer.requestAddMusic")
    static let requestEditInfo = Notification.Name("MusicPlayer.requestEditInfo")
    static let requestLocatePlayingTrack = Notification.Name("MusicPlayer.requestLocatePlayingTrack")
    static let requestShowColumnsPopover = Notification.Name("MusicPlayer.requestShowColumnsPopover")
    static let requestShowFontPopover = Notification.Name("MusicPlayer.requestShowFontPopover")
    static let requestIncreaseFontSize = Notification.Name("MusicPlayer.requestIncreaseFontSize")
    static let requestDecreaseFontSize = Notification.Name("MusicPlayer.requestDecreaseFontSize")
}
