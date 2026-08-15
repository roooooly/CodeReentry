import SwiftUI

struct GlobalDestinationView: View {
    let destination: GlobalDestination

    var body: some View {
        ZStack {
            DevHubPaperBackground()
            switch destination {
            case .projects:
                ProjectsOverviewView()
            case .usage:
                UsageOverviewView()
            case .subscriptions:
                GlobalSubscriptionsView()
            case .sessions:
                AllSessionsView()
            case .platforms:
                GlobalPlatformsView()
            }
        }
    }
}
