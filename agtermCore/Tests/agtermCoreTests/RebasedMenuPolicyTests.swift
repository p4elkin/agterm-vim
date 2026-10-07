import Testing
@testable import agtermCore

struct RebasedMenuPolicyTests {
    @Test(arguments: [
        (RebasedMenuPolicy.KeyWindow.agterm, false, RebasedMenuPolicy.Menu.ide, Optional(RebasedMenuPolicy.Menu.agterm)),
        (.agterm, true, .sacrificial, .agterm),
        (.agterm, true, .agterm, nil),
        (.ide, false, .agterm, .sacrificial),
        (.ide, false, .sacrificial, nil),
        (.ide, true, .agterm, .ide),
        (.ide, true, .sacrificial, .ide),
        (.ide, true, .ide, nil),
        (.other, false, .agterm, nil),
        (.other, true, .ide, nil),
        (.other, false, .sacrificial, nil),
    ])
    func installsOnlyTheMenuTheKeyWindowNeeds(_ keyWindow: RebasedMenuPolicy.KeyWindow, _ sacrificialInstalled: Bool,
                                              _ installedMenu: RebasedMenuPolicy.Menu, _ expected: RebasedMenuPolicy.Menu?) {
        let policy = RebasedMenuPolicy(keyWindow: keyWindow, sacrificialInstalled: sacrificialInstalled, installedMenu: installedMenu)
        #expect(policy.menuToInstall == expected)
    }

    @Test(arguments: [
        (RebasedMenuPolicy.Menu.agterm, true), (.ide, false), (.sacrificial, false),
    ])
    func reconciliationTouchesOnlyTheAgtermMenu(_ installedMenu: RebasedMenuPolicy.Menu, _ allowed: Bool) {
        let policy = RebasedMenuPolicy(keyWindow: .other, sacrificialInstalled: true, installedMenu: installedMenu)
        #expect(policy.reconcileAllowed == allowed)
    }
}
