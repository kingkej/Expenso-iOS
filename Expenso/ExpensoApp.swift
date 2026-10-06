//
//  ExpensoApp.swift
//  Expenso
//
//  Created by Sameer Nawaz on 31/01/21.
//

import SwiftUI
import CoreData

@main
struct ExpensoApp: App {
    @StateObject private var ledgerMutations = LedgerMutationService()
    @AppStorage(AppAccent.storageKey) private var accentSelection = AppAccent.original.rawValue
    // Authentication is decided at launch; appearance updates must not reset the session.
    @State private var requiresAuthenticationAtLaunch = UserDefaults.standard.bool(forKey: UD_USE_BIOMETRIC)
    
    init() {
        self.setDefaultPreferences()
    }
    
    private func setDefaultPreferences() {
        if UserDefaults.standard.string(forKey: CurrencySettings.key) == nil {
            UserDefaults.standard.set("RUB", forKey: CurrencySettings.key)
        }
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if requiresAuthenticationAtLaunch {
                    AuthenticateView()
                } else {
                    ExpensoTabView()
                }
            }
            .environment(\.managedObjectContext, persistentContainer.viewContext)
            .environmentObject(ledgerMutations)
            .environment(\.appAccentColor, AppAccent.resolve(accentSelection).color)
            .tint(AppAccent.resolve(accentSelection).color)
        }
    }
    
    var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "Expenso")
        for description in container.persistentStoreDescriptions {
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        })
        return container
    }()
}

struct ExpensoTabView: View {
    @State private var selectedTab = 0
    @EnvironmentObject private var ledgerMutations: LedgerMutationService
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Dashboard", systemImage: "chart.pie", value: 0) {
                ExpenseView().environment(\.motionReflectionsAllowed, selectedTab == 0)
            }
            Tab("Insights", systemImage: "chart.bar.xaxis", value: 1) {
                InsightsView().environment(\.motionReflectionsAllowed, selectedTab == 1)
            }
            Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: 2) { SpendingChatView() }
        }
        .id(ledgerMutations.restoreGeneration)
        .onAppear { SpendingClassificationStore.shared.updateIfDue(context: context) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { SpendingClassificationStore.shared.updateIfDue(context: context) }
            else { SpendingClassificationStore.shared.cancel() }
        }
        .onChange(of: ledgerMutations.restoreGeneration) { _, _ in SpendingClassificationStore.shared.cancel() }
    }
}
