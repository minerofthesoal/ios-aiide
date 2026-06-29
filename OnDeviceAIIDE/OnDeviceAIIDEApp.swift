// MARK: - App Entry Point
// OnDeviceAIIDE/OnDeviceAIIDEApp.swift

import SwiftUI

@main
struct OnDeviceAIIDEApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @State private var theme = AppTheme()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(theme)
                .preferredColorScheme(.dark)
                .accentColor(Color.appCrimson)
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Configure appearance
        configureAppearance()
        return true
    }
    
    private func configureAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Color.appSurface)
        appearance.titleTextAttributes = [
            .foregroundColor: UIColor(Color.appTextPrimary)
        ]
        appearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor(Color.appTextPrimary)
        ]
        
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(Color.appSurface)
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        
        // Table view styling
        UITableView.appearance().backgroundColor = UIColor(Color.appBackground)
        UITableViewCell.appearance().backgroundColor = UIColor(Color.appSurface)
        
        // Remove separator insets for cleaner look
        UITableView.appearance().separatorInset = .zero
        UITableView.appearance().separatorColor = UIColor(Color.appDivider)
    }
}
