import XCTest
@testable import LittleSendCore

final class MailProviderTests: XCTestCase {

    /// LittleSend's connection starts encrypted, so a provider is only listed
    /// as working if it documents a port that does that.
    func testSupportedProvidersUseTheEncryptedFromTheStartPort() {
        for provider in MailProvider.allCases where provider.isSupported && provider != .other {
            XCTAssertEqual(provider.port, 465, "\(provider)")
            XCTAssertNotNil(provider.server, "\(provider)")
        }
    }

    func testICloudAndOutlookAreNotSupported() {
        XCTAssertFalse(MailProvider.icloud.isSupported)
        XCTAssertFalse(MailProvider.outlook.isSupported)
        XCTAssertEqual(MailProvider.icloud.port, 587)
        XCTAssertEqual(MailProvider.outlook.port, 587)
    }

    func testEverySupportedPresetHasAPasswordGuide() {
        for provider in [MailProvider.gmail, .yahoo, .fastmail] {
            XCTAssertNotNil(provider.passwordGuide, "\(provider)")
            XCTAssertNotNil(provider.passwordGuideTitle, "\(provider)")
            XCTAssertEqual(provider.passwordGuide?.scheme, "https")
            XCTAssertFalse(provider.passwordNote.isEmpty)
        }
    }

    func testUnsupportedProvidersExplainAndOfferAWayOut() {
        for provider in [MailProvider.icloud, .outlook] {
            XCTAssertTrue(provider.unsupportedNote.contains(provider.displayName))
            XCTAssertTrue(provider.unsupportedNote.contains("free Gmail account"))
        }
        XCTAssertEqual(MailProvider.freeGmailSignup.scheme, "https")
    }

    func testDetectsTheProviderFromASavedServer() {
        XCTAssertEqual(MailProvider.detect(host: "smtp.gmail.com"), .gmail)
        XCTAssertEqual(MailProvider.detect(host: "  SMTP.Fastmail.COM "), .fastmail)
        XCTAssertEqual(MailProvider.detect(host: "smtp.mail.yahoo.com"), .yahoo)
        XCTAssertEqual(MailProvider.detect(host: "smtp.mail.me.com"), .icloud)
        XCTAssertEqual(MailProvider.detect(host: "mail.example.org"), .other)
    }

    /// A new install has Gmail's server in place; a cleared field is a blank
    /// start, not a custom setup.
    func testAnEmptyServerCountsAsGmail() {
        XCTAssertEqual(MailProvider.detect(host: ""), .gmail)
        XCTAssertEqual(MailProvider.detect(host: "   "), .gmail)
    }

    func testNamesAreUnique() {
        let names = MailProvider.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testStartTLSPortsGetAHint() {
        XCTAssertTrue(SMTPClient.portHint(for: 587).contains("port 465"))
        XCTAssertTrue(SMTPClient.portHint(for: 25).contains("Port 25 "))
        XCTAssertFalse(SMTPClient.portHint(for: 25).isEmpty)
        XCTAssertEqual(SMTPClient.portHint(for: 465), "")
    }
}

final class SetupDestinationsTests: XCTestCase {

    private func draft(kindle: String = "", from: String = "", host: String = "smtp.gmail.com",
                       user: String = "", password: String = "") -> SettingsDraft {
        SettingsDraft(kindleAddress: kindle, fromAddress: from, smtpHost: host, smtpPort: 465,
                      smtpUsername: user, smtpPassword: password)
    }

    private let complete = (kindle: "me@kindle.com", from: "me@gmail.com", user: "me@gmail.com", password: "pw")

    /// The bug: setup ended with Kindle still switched on and no Kindle
    /// address, so the very first Send was refused.
    func testSkippingEverythingStillLeavesASendThatWorks() {
        var d = draft()
        XCTAssertFalse(d.validationProblems.isEmpty, "a fresh install cannot send until setup says where")

        d.chooseDestinationsAfterSetup(firstRun: true)

        XCTAssertFalse(d.sendToKindle)
        XCTAssertTrue(d.saveToDesktop)
        XCTAssertTrue(d.validationProblems.isEmpty, "\(d.validationProblems)")
    }

    func testAKindleWithNoWayToMailItFallsBackToTheDesktop() {
        var d = draft(kindle: complete.kindle)
        d.chooseDestinationsAfterSetup(firstRun: true)

        XCTAssertFalse(d.sendToKindle)
        XCTAssertTrue(d.saveToDesktop)
        XCTAssertTrue(d.validationProblems.isEmpty, "\(d.validationProblems)")
        XCTAssertEqual(d.kindleAddress, complete.kindle, "the address is kept for later")
    }

    func testMailWithNoKindleFallsBackToTheDesktop() {
        var d = draft(from: complete.from, user: complete.user, password: complete.password)
        d.chooseDestinationsAfterSetup(firstRun: true)

        XCTAssertFalse(d.sendToKindle)
        XCTAssertTrue(d.validationProblems.isEmpty, "\(d.validationProblems)")
    }

    func testAFullSetupSwitchesKindleOnForAFirstRun() {
        var d = draft(kindle: complete.kindle, from: complete.from, user: complete.user, password: complete.password)
        d.sendToKindle = false
        d.chooseDestinationsAfterSetup(firstRun: true)

        XCTAssertTrue(d.sendToKindle)
        XCTAssertTrue(d.validationProblems.isEmpty, "\(d.validationProblems)")
    }

    /// Running setup again must not undo a choice made in the panel.
    func testRunningSetupAgainLeavesAWorkingChoiceAlone() {
        var d = draft(kindle: complete.kindle, from: complete.from, user: complete.user, password: complete.password)
        d.sendToKindle = false
        d.saveToDesktop = true
        d.chooseDestinationsAfterSetup(firstRun: false)

        XCTAssertFalse(d.sendToKindle)
        XCTAssertTrue(d.saveToDesktop)
    }

    func testCanSendMailNeedsEveryDetail() {
        XCTAssertTrue(draft(from: "me@gmail.com", user: "me@gmail.com", password: "pw").canSendMail)
        XCTAssertFalse(draft(from: "me@gmail.com", user: "me@gmail.com", password: "").canSendMail)
        XCTAssertFalse(draft(from: "not-an-address", user: "x", password: "pw").canSendMail)
        XCTAssertFalse(draft(from: "me@gmail.com", host: "", user: "me@gmail.com", password: "pw").canSendMail)
        XCTAssertFalse(draft(from: "me@gmail.com", user: "", password: "pw").canSendMail)
    }
}
