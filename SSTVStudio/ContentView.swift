import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ListenView()
                .tabItem { Label("Listen", systemImage: "waveform") }
            MakeView()
                .tabItem { Label("Make", systemImage: "photo") }
            DecodeView()
                .tabItem { Label("Decode", systemImage: "waveform.badge.magnifyingglass") }
        }
    }
}
