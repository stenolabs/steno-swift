import Observation

@MainActor
@Observable
final class NavigationRouter {
    var selection: SidebarItem? = .recording
}
