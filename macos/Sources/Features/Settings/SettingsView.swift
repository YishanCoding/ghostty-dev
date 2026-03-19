import SwiftUI

/// The root settings view with System and Ghostty Dev tabs.
struct SettingsView: View {
    var body: some View {
        TabView {
            SystemSettingsTab()
                .tabItem {
                    Label("System", systemImage: "gearshape")
                }

            GhosttyDevSettingsTab()
                .tabItem {
                    Label("Ghostty Dev", systemImage: "sparkle")
                }
        }
        .frame(width: 480, height: 400)
    }
}

// MARK: - System Settings Tab

/// Settings that map to config.ghostty key-value pairs.
struct SystemSettingsTab: View {
    @ObservedObject private var config = GhosttyConfigStore.shared

    var body: some View {
        Form {
            Section("Window") {
                Picker("Save state:", selection: $config.windowSaveState) {
                    Text("Default").tag("default")
                    Text("Always").tag("always")
                    Text("Never").tag("never")
                }
            }

            Section("App Icon") {
                Picker("Style:", selection: $config.macosIcon) {
                    Text("Default").tag("")
                    Text("Custom Style").tag("custom-style")
                    Text("Blueprint").tag("blueprint")
                    Text("Glass").tag("glass")
                    Text("Holographic").tag("holographic")
                    Text("Paper").tag("paper")
                    Text("Retro").tag("retro")
                    Text("Xray").tag("xray")
                }

                if config.macosIcon == "custom-style" {
                    TextField("Ghost color:", text: $config.macosIconGhostColor)
                        .textFieldStyle(.roundedBorder)
                    TextField("Screen color:", text: $config.macosIconScreenColor)
                        .textFieldStyle(.roundedBorder)
                    Picker("Frame:", selection: $config.macosIconFrame) {
                        Text("Default").tag("")
                        Text("Aluminum").tag("aluminum")
                        Text("Beige").tag("beige")
                        Text("Chrome").tag("chrome")
                        Text("Plastic").tag("plastic")
                    }
                }
            }

            Section {
                Button("Open Config File...") {
                    config.openInEditor()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

// MARK: - Ghostty Dev Settings Tab

/// Settings for Ghostty Dev custom features, stored in UserDefaults.
struct GhosttyDevSettingsTab: View {
    @AppStorage("SidebarShowProgressBadge") private var showProgressBadge: Bool = false
    @AppStorage("SidebarShowCardBorder") private var showCardBorder: Bool = true
    @AppStorage("SidebarFontSize") private var sidebarFontSize: Double = 12

    var body: some View {
        Form {
            Section("Sidebar") {
                Toggle("Show progress badge below tabs", isOn: $showProgressBadge)
                Toggle("Show tab card border", isOn: $showCardBorder)
                Picker("Font size:", selection: $sidebarFontSize) {
                    ForEach([10, 12, 14, 16, 18] as [Double], id: \.self) { size in
                        Text("\(Int(size))pt").tag(size)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}
