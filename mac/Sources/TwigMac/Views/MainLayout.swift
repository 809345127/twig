import SwiftUI

struct MainLayout: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 400)
            VSplitView {
                GraphPane()
                    .frame(minHeight: 150)
                DetailPane()
                    .frame(minHeight: 180)
            }
            .frame(minWidth: 500)
        }
        .toolbar { RepoToolbar() }
    }
}
