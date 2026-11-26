import Foundation
import Testing
@testable import Dynotch

/// What a profile keeps of Orbit's look, and how profiles saved before Orbit still read. Every
/// setting here goes to the scratch defaults.
@MainActor
@Suite(.serialized)
struct ProfileSettingTests {
    private let settings = AppSettings.shared

    init() {
        SnapshotRenderer.useScratchDefaults()
        settings.notchAppearance = .system
        settings.notchAccent = .cobalt
        settings.buttonRadius = 3
        settings.sectionPlacement = .under
        settings.rowActionMode = .hover
        settings.notchMotion = .springy
        settings.closedNotchShows = .dots
        settings.openWidth = 720
        settings.openHeight = 360
        settings.showTrayTab = true
        settings.showNotesTab = true
    }

    /// A profile as 1.5 saved it: the old sizes, Black or Glass and its corners, and none of Orbit's keys.
    private static let savedBeforeOrbit = """
    {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Work","values":{
      "openWidth":680,"openHeight":220,"notchMaterial":"glass","notchAccent":"lavender",
      "notchTopRadius":16,"notchBottomRadius":38,"showTrayTab":false,"showFocusTab":true,
      "homeWidgetA":"weather","hoverDelay":0.25,"pinnedShortcuts":["Morning routine"]}}
    """

    @Test func aProfileKeepsOrbitsLook() {
        let values = ProfileSetting.values(of: settings)
        for key in ["notchAppearance", "orbitAccent", "buttonRadius", "sectionPlacement", "rowActionMode",
                    "notchMotion", "closedNotchShows", "orbitOpenWidth", "orbitOpenHeight", "showNotesTab"] {
            #expect(values[key] != nil, "\(key) isn't kept")
        }
        for key in ["notchMaterial", "notchTopRadius", "notchBottomRadius", "openWidth", "openHeight", "notchAccent"] {
            #expect(values[key] == nil, "\(key) is still kept")
        }
    }

    @Test func switchingBackPutsTheLookBack() {
        settings.notchAppearance = .light
        settings.notchAccent = .teal
        settings.buttonRadius = 9
        settings.sectionPlacement = .arc
        settings.rowActionMode = .menu
        settings.notchMotion = .minimal
        settings.closedNotchShows = .nothing
        settings.openWidth = 840
        settings.openHeight = 420
        let saved = ProfileSetting.values(of: settings)

        settings.notchAppearance = .dark
        settings.notchAccent = .orange
        settings.buttonRadius = 0
        settings.sectionPlacement = .left
        settings.rowActionMode = .always
        settings.notchMotion = .smooth
        settings.closedNotchShows = .activities
        settings.openWidth = 640
        settings.openHeight = 300
        ProfileSetting.apply(saved, to: settings)

        #expect(settings.notchAppearance == .light)
        #expect(settings.notchAccent == .teal)
        #expect(settings.buttonRadius == 9)
        #expect(settings.sectionPlacement == .arc)
        #expect(settings.rowActionMode == .menu)
        #expect(settings.notchMotion == .minimal)
        #expect(settings.closedNotchShows == .nothing)
        #expect(settings.openWidth == 840)
        #expect(settings.openHeight == 420)
    }

    @Test func aProfileFromBeforeOrbitStillReads() throws {
        let profile = try JSONDecoder().decode(Profile.self, from: Data(Self.savedBeforeOrbit.utf8))
        #expect(profile.name == "Work")

        ProfileSetting.apply(profile.values, to: settings)

        // What it knows still switches.
        #expect(settings.showTrayTab == false)
        #expect(settings.homeWidgetA == .weather)
        #expect(settings.hoverDelay == 0.25)
        // Its sizes, accent and corners were for the old notch: Orbit's stay as they were.
        #expect(settings.openWidth == 720)
        #expect(settings.openHeight == 360)
        #expect(settings.notchAccent == .cobalt)
        #expect(settings.buttonRadius == 3)
        #expect(settings.notchAppearance == .system)
        #expect(settings.sectionPlacement == .under)
    }

    @Test func savingAnOldProfileAgainDropsWhatOrbitDoesntUse() throws {
        var profile = try JSONDecoder().decode(Profile.self, from: Data(Self.savedBeforeOrbit.utf8))
        ProfileSetting.apply(profile.values, to: settings)
        profile.values = ProfileSetting.values(of: settings)

        let data = try JSONEncoder().encode(profile)
        let again = try JSONDecoder().decode(Profile.self, from: data)
        #expect(again.values["notchMaterial"] == nil)
        #expect(again.values["notchTopRadius"] == nil)
        #expect(again.values["orbitAccent"] == .text("cobalt"))
        #expect(again.values["orbitOpenHeight"] == .number(360))
        #expect(again.values["showTrayTab"] == .bool(false))
    }

    @Test func numbersOutOfRangeAreKeptInIt() {
        ProfileSetting.apply(["buttonRadius": .number(40), "orbitOpenWidth": .number(2000), "orbitOpenHeight": .number(120)],
                             to: settings)
        #expect(settings.buttonRadius == 16)
        #expect(settings.openWidth == AppSettings.openWidthRange.upperBound)
        #expect(settings.openHeight == AppSettings.openHeightRange.lowerBound)

        ProfileSetting.apply(["buttonRadius": .number(-.infinity), "sectionPlacement": .text("somewhere")], to: settings)
        #expect(settings.buttonRadius == 16)
        #expect(settings.sectionPlacement == .under)
    }
}
