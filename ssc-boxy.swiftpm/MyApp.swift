import SwiftUI
import CoreText
import UIKit

@main
struct MyApp: App {
    init() {
        registerFonts()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
    
    private func registerFonts() {
        // Use Bundle.module if available, fallback to Bundle.main
        let bundle: Bundle = {
            #if SWIFT_PACKAGE
            return Bundle.module
            #else
            return Bundle.main
            #endif
        }()
        
        guard let fontURL = bundle.url(forResource: "LED Dot-Matrix", withExtension: "ttf") ??
                             bundle.url(forResource: "LED Dot-Matrix", withExtension: "ttf", subdirectory: "Fonts") ??
                             bundle.url(forResource: "LED Dot-Matrix", withExtension: "ttf", subdirectory: "Resources/Fonts") else {
            print("❌ Could not find font file: LED Dot-Matrix.ttf")
            return
        }
        
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error) {
            let errorDescription = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            print("⚠️ Font registration note: \(errorDescription)")
        } else {
            print("✅ Successfully registered font: LED Dot-Matrix.ttf")
        }
    }
}
