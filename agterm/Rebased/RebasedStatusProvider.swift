import agtermCore

@MainActor
enum RebasedStatusProvider {
    static var status: () -> ControlRebasedNode = { RebasedHost.shared.status }

    static var readback: ControlRebasedNode? {
        let current = status()
        return current.jvm == "notStarted" ? nil : current
    }
}
