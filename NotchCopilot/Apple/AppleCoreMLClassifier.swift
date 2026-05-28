import CoreML
import Foundation

struct AppleCoreMLClassifier {
    func supportsModel(named name: String) -> Bool {
        Bundle.main.url(forResource: name, withExtension: "mlmodelc") != nil
    }

    func classify(text: String) -> MeetingType {
        if text.localizedCaseInsensitiveContains("architecture") || text.localizedCaseInsensitiveContains("bug") {
            return .engineering
        }
        if text.localizedCaseInsensitiveContains("campaign") {
            return .marketing
        }
        if text.localizedCaseInsensitiveContains("candidate") {
            return .interview
        }
        return .general
    }
}

