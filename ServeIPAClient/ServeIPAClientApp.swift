//
//  ServeIPAClientApp.swift
//  ServeIPAClient
//
//  Created by Arnaud CAPDEPON on 03/11/2026.
//

import SwiftUI

@main
struct ServeIPAClientApp: App {
    init() {
        ClientNotifications.shared.activate()
    }

    var body: some Scene {
        WindowGroup("ServeIPA Client") {
            ContentView()
                #if os(macOS)
                // Un lien serveipa:// va à la fenêtre déjà ouverte, au lieu d'en ouvrir une seconde.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                #endif
        }
        #if os(macOS)
        // Sans fenêtre ouverte, le lien en crée une.
        .handlesExternalEvents(matching: ["*"])
        #endif
        #if os(iOS)
        .backgroundTask(.appRefresh(JobRefresh.identifier)) {
            if await ClientStore().checkJobsInBackground() { JobRefresh.schedule() }
        }
        #endif
    }
}
