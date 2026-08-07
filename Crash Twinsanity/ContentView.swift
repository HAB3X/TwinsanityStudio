//
//  ContentView.swift
//  Crash Twinsanity
//
//  Created by Marcus Chandler on 7/8/2026.
//

import SwiftUI

/// Hosts the SceneKit-based game view controller inside the SwiftUI window.
struct ContentView: View {
    var body: some View {
        GameViewControllerRepresentable()
            .ignoresSafeArea()
    }
}

struct GameViewControllerRepresentable: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> GameViewController {
        return GameViewController()
    }

    func updateNSViewController(_ nsViewController: GameViewController, context: Context) {
        // No dynamic updates needed; the game manages its own state.
    }
}

#Preview {
    ContentView()
}
