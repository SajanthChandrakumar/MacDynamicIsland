//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id: String
    let label: LocalizedStringKey
    let icon: String
    let view: NotchViews
}

private let defaultTabs = [
    TabModel(id: "home", label: "Home", icon: "house.fill", view: .home),
    TabModel(id: "shelf", label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(id: "focus", label: "Focus", icon: "timer", view: .focus)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.boringShelf) var shelfEnabled
    @Namespace var animation
    var body: some View {
        let visibleTabs = defaultTabs.filter { $0.view != .shelf || shelfEnabled }
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notch tabs")
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
