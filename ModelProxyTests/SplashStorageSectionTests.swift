import Foundation
import Testing
@testable import ZGate

/// Pure editing rules behind the storage section's size fields (fix round
/// 1): the quota Custom field must stay editable through invalid
/// intermediates, and those intermediates must never reach the config.
@Suite struct SplashStorageSectionTests {

    // Finding 3: what a keystroke persists.
    @Test func sizeInputKeepsLastValidOnInvalidIntermediate() {
        #expect(SplashStorageSection.resolveSizeInput("20G", lastValid: "16G") == "20G")   // valid → persist
        #expect(SplashStorageSection.resolveSizeInput("1.5G", lastValid: "16G") == "1.5G")
        #expect(SplashStorageSection.resolveSizeInput(" 20G ", lastValid: nil) == "20G")   // trimmed valid
        // The bug's exact shape: backspacing "16G" → "16" must not wipe
        // the quota from config — the last valid value survives.
        #expect(SplashStorageSection.resolveSizeInput("16", lastValid: "16G") == "16G")
        #expect(SplashStorageSection.resolveSizeInput("16g", lastValid: "16G") == "16G")   // case matters
        #expect(SplashStorageSection.resolveSizeInput("16", lastValid: nil) == nil)   // nothing prior to keep
        #expect(SplashStorageSection.resolveSizeInput("", lastValid: "16G") == nil)   // empty = flag omitted
    }

    // Finding 1: picker → Custom seeds a starter unless a custom value
    // already exists (a user mid-edit must not have their text replaced).
    @Test func quotaCustomSeedOnlyWhenNothingCustom() {
        #expect(SplashStorageSection.quotaCustomSeed(persisted: nil) == "16G")
        #expect(SplashStorageSection.quotaCustomSeed(persisted: "0") == "16G")   // Off → Custom re-seeds
        #expect(SplashStorageSection.quotaCustomSeed(persisted: "20G") == "20G")   // existing custom survives
    }

    // Picker selection ↔ persisted value (spec §2: nil = auto, "0" = off).
    @Test func quotaModeDerivation() {
        #expect(SplashStorageSection.quotaMode(for: nil) == .auto)
        #expect(SplashStorageSection.quotaMode(for: "") == .auto)
        #expect(SplashStorageSection.quotaMode(for: "0") == .off)
        #expect(SplashStorageSection.quotaMode(for: "20G") == .custom)
    }
}
