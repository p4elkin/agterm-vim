public struct RebasedMenuPolicy: Sendable {
    public enum KeyWindow: Sendable {
        case agterm, ide, other
    }

    public enum Menu: Sendable {
        case agterm, sacrificial, ide
    }

    public let keyWindow: KeyWindow
    public let sacrificialInstalled: Bool
    public let installedMenu: Menu

    public init(keyWindow: KeyWindow, sacrificialInstalled: Bool, installedMenu: Menu) {
        self.keyWindow = keyWindow
        self.sacrificialInstalled = sacrificialInstalled
        self.installedMenu = installedMenu
    }

    public var menuToInstall: Menu? {
        let desired: Menu
        switch keyWindow {
        case .agterm: desired = .agterm
        case .ide: desired = sacrificialInstalled ? .ide : .sacrificial
        case .other: return nil
        }
        return desired == installedMenu ? nil : desired
    }

    public var reconcileAllowed: Bool { installedMenu == .agterm }
}
