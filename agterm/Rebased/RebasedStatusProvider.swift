import agtermCore

@MainActor
enum RebasedStatusProvider {
    static var status: () -> ControlRebasedNode = { .init(jvm: "notStarted") }

    static var readback: ControlRebasedNode? {
        let current = status()
        return current.jvm == "notStarted" ? nil : current
    }
}
