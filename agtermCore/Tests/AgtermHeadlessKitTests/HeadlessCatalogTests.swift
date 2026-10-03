import Testing
import agtermCore
import AgtermHeadlessKit

struct HeadlessCatalogTests {
    @Test(arguments: [
        "tree", "events.read", "version", "window.list", "zmx.new", "zmx.tree", "zmx.present", "zmx.list",
        "notify", "session.status", "session.context", "session.seen", "session.new", "session.mark",
        "session.close", "session.rename", "zmx.kill", "session.split", "session.split.close", "session.swap", "session.text",
        "session.type",
        "session.hud.open", "session.hud.update", "session.hud.close", "ask.open", "ask.result", "ask.cancel",
        "session.overlay.job.run",
    ])
    func phaseOneCommandsAreServed(_ name: String) throws {
        let command = try #require(Command(rawValue: name))

        #expect(HeadlessCatalog.support(for: command) == .served)
    }

    @Test(arguments: [
        "window.new", "window.select", "window.go", "window.close", "window.rename", "window.delete",
        "window.resize", "window.move", "window.zoom", "window.fullscreen", "window.minimize",
        "workspace.new", "workspace.rename", "workspace.delete", "workspace.select", "workspace.go",
        "workspace.move", "workspace.focus", "workspace.filter", "workspace.collapse", "workspace.expand",
        "sidebar", "sidebar.mode", "sidebar.flagged-layout", "sidebar.expand", "sidebar.collapse",
        "sidebar.parked", "sidebar.width", "mode", "theme.set", "theme.list", "font.inc", "font.dec",
        "font.reset", "keymap.reload", "keymap.list", "config.reload", "quick", "quick.type", "quick.text",
        "dashboard", "debug.appearance", "session.go", "session.move",
        "session.duplicate", "session.park", "session.resize",
    ])
    func windowAndUICommandsAreRefused(_ name: String) throws {
        try expectRefusal(name, reason: "no windows or UI")
    }

    @Test(arguments: [
        "surface.zoom", "surface.cursor", "session.scratch", "session.lead",
    ])
    func terminalSurfaceCommandsAreRefused(_ name: String) throws {
        try expectRefusal(name, reason: "no terminal surface")
    }

    @Test(arguments: [
        "session.pairing", "overlay-redirect.toggle", "hooks.reload", "hooks.list", "session.restore",
        "restore.clear", "restore.capture", "restore.mode", "zmx.prune", "zmx.reset",
    ])
    func macFeaturesAreRefused(_ name: String) throws {
        try expectRefusal(name, reason: "a Mac feature")
    }

    @Test(arguments: [
        "session.overlay.reload", "session.overlay.navigate", "session.overlay.submit", "session.overlay.copy",
        "session.overlay.text", "pick.open", "pick.result", "pick.cancel",
        "session.flag", "session.select", "session.reveal", "session.focus", "session.background",
        "session.copy", "session.paste", "session.selectall", "session.search",
        "session.bookmark.add", "session.bookmark.list", "session.bookmark.go", "session.bookmark.remove",
    ])
    func macUICommandsAreForwarded(_ name: String) throws {
        #expect(HeadlessCatalog.support(for: try #require(Command(rawValue: name))) == .forwarded)
    }

    @Test(arguments: [
        "session.overlay.open", "session.overlay.close", "session.overlay.resize", "session.overlay.result", "zmx.attach",
    ])
    func theOverlayFamilyAndAttachAreRoutedPerRequest(_ name: String) throws {
        #expect(HeadlessCatalog.support(for: try #require(Command(rawValue: name))) == .routed)
    }

    private func expectRefusal(_ name: String, reason: String) throws {
        let command = try #require(Command(rawValue: name))

        #expect(HeadlessCatalog.support(for: command) == .refused("\(name) is not available on a headless origin: \(reason)"))
    }
}
