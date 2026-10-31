import SwiftUI

/// The workflow's name in the left ear.
struct CILabel: View {
    let run: CIRun

    var body: some View { EmptyView() }
}

/// How the run is going, in the right ear.
struct CIStatus: View {
    let run: CIRun

    var body: some View { EmptyView() }
}

/// The ring at the end of the right ear.
struct CIGlyph: View {
    let run: CIRun

    var body: some View { EmptyView() }
}

/// The run, in the glance, with its button.
struct CIGlance: View {
    let run: CIRun
    let band: CGFloat

    var body: some View { EmptyView() }
}

extension SnapshotRenderer {
    static func ciScenes() -> [Scene] { [] }
}
