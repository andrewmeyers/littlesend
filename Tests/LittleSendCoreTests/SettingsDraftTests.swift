import XCTest
@testable import LittleSendCore

final class SettingsDraftTests: XCTestCase {

    private func draft(
        kindle: String = "me@kindle.com",
        from: String = "me@gmail.com",
        host: String = "smtp.gmail.com",
        user: String = "me@gmail.com",
        password: String = "secret",
        key: String = "abc123"
    ) -> SettingsDraft {
        SettingsDraft(
            kindleAddress: kindle, fromAddress: from, smtpHost: host,
            smtpPort: 465, smtpUsername: user, smtpPassword: password,
            instaparserAPIKey: key
        )
    }

    // MARK: - Normalization

    func testWhitespaceIsTrimmedFromEveryField() {
        let messy = draft(
            kindle: "  me@kindle.com ", from: "me@gmail.com\n", host: " smtp.gmail.com",
            user: "\tme@gmail.com ", password: " secret ", key: "  abc123  "
        )
        let clean = messy.normalized

        XCTAssertEqual(clean.kindleAddress, "me@kindle.com")
        XCTAssertEqual(clean.fromAddress, "me@gmail.com")
        XCTAssertEqual(clean.smtpHost, "smtp.gmail.com")
        XCTAssertEqual(clean.smtpUsername, "me@gmail.com")
        XCTAssertEqual(clean.smtpPassword, "secret")
        XCTAssertEqual(clean.instaparserAPIKey, "abc123")
    }

    func testNormalizationIsIdempotent() {
        let once = draft(kindle: "  me@kindle.com  ").normalized
        XCTAssertEqual(once, once.normalized)
    }

    func testPaddedInputIsNotTreatedAsAChange() {
        // Drives the Save button's enabled state.
        XCTAssertEqual(draft(kindle: " me@kindle.com ").normalized, draft().normalized)
    }

    func testRealEditIsTreatedAsAChange() {
        XCTAssertNotEqual(draft(kindle: "other@kindle.com").normalized, draft().normalized)
    }

    // MARK: - Gmail app passwords

    func testSpacedGmailAppPasswordIsCollapsed() {
        // Google displays app passwords in four groups; the credential has no spaces.
        XCTAssertEqual(SettingsDraft.normalizeAppPassword("abcd efgh ijkl mnop"), "abcdefghijklmnop")
        XCTAssertEqual(SettingsDraft.normalizeAppPassword("  abcd efgh ijkl mnop  "), "abcdefghijklmnop")
    }

    func testAlreadyCollapsedAppPasswordIsUnchanged() {
        XCTAssertEqual(SettingsDraft.normalizeAppPassword("abcdefghijklmnop"), "abcdefghijklmnop")
    }

    func testOrdinaryPasswordsKeepTheirSpaces() {
        // A real passphrase must survive untouched.
        XCTAssertEqual(SettingsDraft.normalizeAppPassword("correct horse battery staple"), "correct horse battery staple")
        XCTAssertEqual(SettingsDraft.normalizeAppPassword("my secret pw"), "my secret pw")
    }

    func testNearMissesAreNotCollapsed() {
        // Wrong group count, wrong group length, or non-lowercase: leave alone.
        XCTAssertEqual(SettingsDraft.normalizeAppPassword("abcd efgh ijkl"), "abcd efgh ijkl")
        XCTAssertEqual(SettingsDraft.normalizeAppPassword("abcde fghi jklm nopq"), "abcde fghi jklm nopq")
        XCTAssertEqual(SettingsDraft.normalizeAppPassword("ABCD efgh ijkl mnop"), "ABCD efgh ijkl mnop")
        XCTAssertEqual(SettingsDraft.normalizeAppPassword("ab1d efgh ijkl mnop"), "ab1d efgh ijkl mnop")
    }

    func testAppPasswordNormalizationRunsInsideNormalized() {
        XCTAssertEqual(draft(password: "abcd efgh ijkl mnop").normalized.smtpPassword, "abcdefghijklmnop")
    }

    func testEmptyPasswordStaysEmpty() {
        XCTAssertEqual(SettingsDraft.normalizeAppPassword(""), "")
        XCTAssertEqual(SettingsDraft.normalizeAppPassword("   "), "")
    }

    // MARK: - Validation

    func testCompleteDraftHasNoProblems() {
        XCTAssertTrue(draft().validationProblems.isEmpty)
    }

    func testValidationSeesThroughWhitespaceOnlyInput() {
        // A field holding only spaces is missing, not present.
        XCTAssertFalse(draft(key: "   ").validationProblems.isEmpty)
        XCTAssertFalse(draft(password: "   ").validationProblems.isEmpty)
    }

    func testConfigurationCarriesNormalizedValues() {
        let configuration = draft(kindle: " me@kindle.com ", password: "abcd efgh ijkl mnop").configuration
        XCTAssertEqual(configuration.kindleAddress, "me@kindle.com")
        XCTAssertEqual(configuration.smtpPassword, "abcdefghijklmnop")
    }

    func testPortIsClampedIntoRange() {
        var oversized = draft()
        oversized.smtpPort = 999_999
        XCTAssertEqual(oversized.configuration.smtpPort, UInt16.max)

        var negative = draft()
        negative.smtpPort = -1
        XCTAssertEqual(negative.configuration.smtpPort, 0)
    }
}

final class SettingsCompletenessTests: XCTestCase {

    /// A fully filled-in draft with no destination selected at all — the state
    /// Settings is in when the user hasn't picked anything in the menu bar.
    private func draft(
        kindle: String = "",
        addresses: [String] = []
    ) -> SettingsDraft {
        SettingsDraft(
            kindleAddress: kindle,
            fromAddress: "me@gmail.com",
            smtpHost: "smtp.gmail.com",
            smtpPort: 465,
            smtpUsername: "me@gmail.com",
            smtpPassword: "pw",
            instaparserAPIKey: "key",
            sendToKindle: false,
            sendToEmail: false,
            emailAddresses: addresses
        )
    }

    func testNoAddressesAtAllIsComplete() {
        // Settings cannot turn a destination on, so it must not demand one.
        XCTAssertEqual(draft().settingsProblems, [])
    }

    func testKindleAloneIsComplete() {
        XCTAssertEqual(draft(kindle: "me@kindle.com").settingsProblems, [])
    }

    func testEmailAloneIsComplete() {
        XCTAssertEqual(draft(addresses: ["a@x.com"]).settingsProblems, [])
    }

    func testNeverComplainsAboutDestinationSelection() {
        // The send-time gate still does; Settings must not.
        let empty = draft()
        XCTAssertFalse(empty.settingsProblems.contains { $0.contains("destination") })
        XCTAssertTrue(empty.validationProblems.contains { $0.contains("destination") })
    }

    // MARK: - What it does still catch

    func testMissingCredentialsAreReportedOnceMailIsConfigured() {
        // SMTP only matters once there is something to mail — see
        // testDesktopOnlyNeedsNoMailCredentials for the other half of this.
        var missing = draft(addresses: ["a@x.com"])
        missing.instaparserAPIKey = ""
        missing.smtpPassword = ""
        let problems = missing.settingsProblems

        XCTAssertTrue(problems.contains { $0.contains("API key") })
        XCTAssertTrue(problems.contains { $0.contains("password") })
    }

    func testDesktopOnlyNeedsNoMailCredentials() {
        // No Kindle address and no email addresses: nothing will ever be
        // mailed, so blank SMTP fields are not a problem to report.
        var bare = draft()
        bare.smtpHost = ""
        bare.smtpUsername = ""
        bare.smtpPassword = ""
        bare.fromAddress = ""
        XCTAssertEqual(bare.settingsProblems, [])
    }

    func testMalformedKindleAddressIsReportedButBlankIsNot() {
        XCTAssertTrue(draft(kindle: "nonsense").settingsProblems.contains { $0.contains("Kindle") })
        XCTAssertFalse(draft(kindle: "").settingsProblems.contains { $0.contains("Kindle") })
    }

    func testMalformedAddressIsCaughtEvenWhenDeselected() {
        // Email is off and the address is excluded — a typo still matters,
        // because Settings is where it gets fixed.
        var typo = draft(addresses: ["good@x.com", "nope"])
        typo.setRecipient("nope", selected: false)
        XCTAssertTrue(typo.settingsProblems.contains { $0.contains("nope") })
    }

    func testMalformedSenderIsReportedOnceMailIsConfigured() {
        var bad = draft(addresses: ["a@x.com"])
        bad.fromAddress = "not-an-address"
        XCTAssertTrue(bad.settingsProblems.contains { $0.contains("Sender") })
    }
}
