import Testing
@testable import Veil

struct ProfileTests {

    @Test func defaultProfile() {
        let profile = Profile.default
        #expect(profile.name == "nvim")
        #expect(profile.displayName == "Default")
    }

    @Test func profileEquality() {
        let a = Profile(name: "nvim", displayName: "Default")
        let b = Profile(name: "nvim", displayName: "Something Else")
        let c = Profile(name: "lazyvim", displayName: "LazyVim")

        #expect(a == b)   // same name => equal
        #expect(a != c)
    }

    @Test func profileHashBasedOnName() {
        var set = Set<Profile>()
        set.insert(Profile(name: "nvim", displayName: "Default"))
        set.insert(Profile(name: "nvim", displayName: "Other Display Name"))
        set.insert(Profile(name: "lazyvim", displayName: "LazyVim"))

        #expect(set.count == 2)
    }

    @Test func profileFromDirectoryName() {
        let profile = Profile(name: "lazyvim", displayName: "lazyvim")
        #expect(profile.name == "lazyvim")
        #expect(profile.displayName == "lazyvim")
    }

    @Test func availableProfilesAlwaysIncludesDefault() {
        let profiles = Profile.availableProfiles()
        #expect(profiles.contains(.default))
    }

    @Test func lastUsedRoundTrip() {
        let original = Profile.lastUsed
        let custom = Profile(name: "test-profile", displayName: "Test Profile")
        Profile.lastUsed = custom
        let retrieved = Profile.lastUsed
        #expect(retrieved == custom)
        #expect(retrieved.displayName == custom.displayName)
        // Restore
        Profile.lastUsed = original
    }
}
