import Foundation

struct QuestionPriorityRule: Codable, Hashable, Sendable {
    var id: String
    var priority: QuestionPriority
    var markers: [String]
    var questionTypes: Set<QuestionType>
    var allSignals: Set<QuestionUnderstandingSignal>
    var anySignals: Set<QuestionUnderstandingSignal>
    var requiresDirectedToUser: Bool?
    var requiresDirectedToGroup: Bool?
    var requiresActionable: Bool?

    init(
        id: String = "",
        priority: QuestionPriority = .low,
        markers: [String] = [],
        questionTypes: Set<QuestionType> = [],
        allSignals: Set<QuestionUnderstandingSignal> = [],
        anySignals: Set<QuestionUnderstandingSignal> = [],
        requiresDirectedToUser: Bool? = nil,
        requiresDirectedToGroup: Bool? = nil,
        requiresActionable: Bool? = nil
    ) {
        self.id = id
        self.priority = priority
        self.markers = markers
        self.questionTypes = questionTypes
        self.allSignals = allSignals
        self.anySignals = anySignals
        self.requiresDirectedToUser = requiresDirectedToUser
        self.requiresDirectedToGroup = requiresDirectedToGroup
        self.requiresActionable = requiresActionable
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case priority
        case markers
        case questionTypes
        case allSignals
        case anySignals
        case requiresDirectedToUser
        case requiresDirectedToGroup
        case requiresActionable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            priority: try container.decodeIfPresent(QuestionPriority.self, forKey: .priority) ?? .low,
            markers: try container.decodeIfPresent([String].self, forKey: .markers) ?? [],
            questionTypes: try container.decodeIfPresent(Set<QuestionType>.self, forKey: .questionTypes) ?? [],
            allSignals: try container.decodeIfPresent(Set<QuestionUnderstandingSignal>.self, forKey: .allSignals) ?? [],
            anySignals: try container.decodeIfPresent(Set<QuestionUnderstandingSignal>.self, forKey: .anySignals) ?? [],
            requiresDirectedToUser: try container.decodeIfPresent(Bool.self, forKey: .requiresDirectedToUser),
            requiresDirectedToGroup: try container.decodeIfPresent(Bool.self, forKey: .requiresDirectedToGroup),
            requiresActionable: try container.decodeIfPresent(Bool.self, forKey: .requiresActionable)
        )
    }
}

struct QuestionPriorityPolicy: Codable, Hashable, Sendable {
    var priorityRules: [QuestionPriorityRule]
    var urgentMarkers: [String]
    var directedHighPriorityTypes: Set<QuestionType>
    var highPriorityTypes: Set<QuestionType>
    var mediumPriorityTypes: Set<QuestionType>
    var directedToUserFloor: QuestionPriority
    var directedToGroupFloor: QuestionPriority
    var actionableFloor: QuestionPriority

    init(
        priorityRules: [QuestionPriorityRule] = [],
        urgentMarkers: [String] = [],
        directedHighPriorityTypes: Set<QuestionType> = [],
        highPriorityTypes: Set<QuestionType> = [],
        mediumPriorityTypes: Set<QuestionType> = [],
        directedToUserFloor: QuestionPriority = .low,
        directedToGroupFloor: QuestionPriority = .low,
        actionableFloor: QuestionPriority = .low
    ) {
        self.priorityRules = priorityRules
        self.urgentMarkers = urgentMarkers
        self.directedHighPriorityTypes = directedHighPriorityTypes
        self.highPriorityTypes = highPriorityTypes
        self.mediumPriorityTypes = mediumPriorityTypes
        self.directedToUserFloor = directedToUserFloor
        self.directedToGroupFloor = directedToGroupFloor
        self.actionableFloor = actionableFloor
    }

    private enum CodingKeys: String, CodingKey {
        case priorityRules
        case urgentMarkers
        case directedHighPriorityTypes
        case highPriorityTypes
        case mediumPriorityTypes
        case directedToUserFloor
        case directedToGroupFloor
        case actionableFloor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            priorityRules: try container.decodeIfPresent([QuestionPriorityRule].self, forKey: .priorityRules) ?? [],
            urgentMarkers: try container.decodeIfPresent([String].self, forKey: .urgentMarkers) ?? [],
            directedHighPriorityTypes: try container.decodeIfPresent(Set<QuestionType>.self, forKey: .directedHighPriorityTypes) ?? [],
            highPriorityTypes: try container.decodeIfPresent(Set<QuestionType>.self, forKey: .highPriorityTypes) ?? [],
            mediumPriorityTypes: try container.decodeIfPresent(Set<QuestionType>.self, forKey: .mediumPriorityTypes) ?? [],
            directedToUserFloor: try container.decodeIfPresent(QuestionPriority.self, forKey: .directedToUserFloor) ?? .low,
            directedToGroupFloor: try container.decodeIfPresent(QuestionPriority.self, forKey: .directedToGroupFloor) ?? .low,
            actionableFloor: try container.decodeIfPresent(QuestionPriority.self, forKey: .actionableFloor) ?? .low
        )
    }

    static let `default` = QuestionPriorityPolicyStore.current
}

enum QuestionPriorityPolicyStore {
    static let current: QuestionPriorityPolicy = load()

    private static func load() -> QuestionPriorityPolicy {
        let decoder = JSONDecoder()
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let policy = try? decoder.decode(QuestionPriorityPolicy.self, from: data) else {
                continue
            }
            return policy.normalized()
        }
        return fallbackPolicy()
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let bundles = [Bundle.main, Bundle(for: QuestionPriorityPolicyBundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(
                forResource: "question-priority-policy",
                withExtension: "json",
                subdirectory: "CopilotIntentPolicy"
            ) {
                urls.append(url)
            }
        }
        urls.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/CopilotIntentPolicy/question-priority-policy.json")
        )
        return urls
    }

    private static func fallbackPolicy() -> QuestionPriorityPolicy {
        QuestionPriorityPolicy(
            priorityRules: [],
            urgentMarkers: [],
            directedHighPriorityTypes: [],
            highPriorityTypes: [],
            mediumPriorityTypes: [],
            directedToUserFloor: .low,
            directedToGroupFloor: .low,
            actionableFloor: .low
        )
    }
}

private final class QuestionPriorityPolicyBundleMarker {}

private extension QuestionPriorityPolicy {
    func normalized() -> QuestionPriorityPolicy {
        QuestionPriorityPolicy(
            priorityRules: priorityRules.map(\.normalizedQuestionPriorityRule),
            urgentMarkers: urgentMarkers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            directedHighPriorityTypes: directedHighPriorityTypes,
            highPriorityTypes: highPriorityTypes,
            mediumPriorityTypes: mediumPriorityTypes,
            directedToUserFloor: directedToUserFloor,
            directedToGroupFloor: directedToGroupFloor,
            actionableFloor: actionableFloor
        )
    }
}

private extension QuestionPriorityRule {
    var normalizedQuestionPriorityRule: QuestionPriorityRule {
        QuestionPriorityRule(
            id: id.trimmingCharacters(in: .whitespacesAndNewlines),
            priority: priority,
            markers: markers.map(QuestionDetectionService.normalize).filter { !$0.isEmpty },
            questionTypes: questionTypes,
            allSignals: allSignals,
            anySignals: anySignals,
            requiresDirectedToUser: requiresDirectedToUser,
            requiresDirectedToGroup: requiresDirectedToGroup,
            requiresActionable: requiresActionable
        )
    }
}

struct QuestionPriorityScorer {
    var policy: QuestionPriorityPolicy = .default
    var textPolicy: QuestionTextSegmentationPolicy = QuestionIntentRulePack.default.textSegmentationPolicy

    func priority(
        for candidate: QuestionCandidate,
        type: QuestionType,
        directedToUser: Bool,
        directedToGroup: Bool,
        actionable: Bool,
        signals: Set<QuestionUnderstandingSignal> = [],
        responseNeeded: Bool
    ) -> QuestionPriority {
        guard responseNeeded else { return .low }
        let text = candidate.normalizedText
        return policy.effectivePriorityRules.reduce(QuestionPriority.low) { current, rule in
            guard matches(
                rule,
                text: text,
                type: type,
                directedToUser: directedToUser,
                directedToGroup: directedToGroup,
                actionable: actionable,
                signals: signals
            ) else {
                return current
            }
            return rule.priority.rank > current.rank ? rule.priority : current
        }
    }

    private func contains(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { pattern in
            textPolicy.containsMarker(pattern, in: text)
        }
    }

    private func matches(
        _ rule: QuestionPriorityRule,
        text: String,
        type: QuestionType,
        directedToUser: Bool,
        directedToGroup: Bool,
        actionable: Bool,
        signals: Set<QuestionUnderstandingSignal>
    ) -> Bool {
        if let required = rule.requiresDirectedToUser, directedToUser != required { return false }
        if let required = rule.requiresDirectedToGroup, directedToGroup != required { return false }
        if let required = rule.requiresActionable, actionable != required { return false }
        if !rule.questionTypes.isEmpty, !rule.questionTypes.contains(type) { return false }
        if !rule.allSignals.isEmpty, !rule.allSignals.isSubset(of: signals) { return false }
        if !rule.anySignals.isEmpty, rule.anySignals.isDisjoint(with: signals) { return false }
        if !rule.markers.isEmpty, !contains(text, rule.markers) { return false }
        return true
    }
}

private extension QuestionPriorityPolicy {
    var effectivePriorityRules: [QuestionPriorityRule] {
        guard priorityRules.isEmpty else { return priorityRules }
        var rules: [QuestionPriorityRule] = []
        if !urgentMarkers.isEmpty {
            rules.append(QuestionPriorityRule(
                id: "legacy_directed_urgent_marker",
                priority: .urgent,
                markers: urgentMarkers,
                requiresDirectedToUser: true
            ))
        }
        if !directedHighPriorityTypes.isEmpty {
            rules.append(QuestionPriorityRule(
                id: "legacy_directed_high_priority_type",
                priority: .high,
                questionTypes: directedHighPriorityTypes,
                requiresDirectedToUser: true
            ))
        }
        if !highPriorityTypes.isEmpty {
            rules.append(QuestionPriorityRule(
                id: "legacy_high_priority_type",
                priority: .high,
                questionTypes: highPriorityTypes
            ))
        }
        if directedToUserFloor != .low {
            rules.append(QuestionPriorityRule(
                id: "legacy_directed_user_floor",
                priority: directedToUserFloor,
                requiresDirectedToUser: true
            ))
        }
        if directedToGroupFloor != .low {
            rules.append(QuestionPriorityRule(
                id: "legacy_directed_group_floor",
                priority: directedToGroupFloor,
                requiresDirectedToGroup: true
            ))
        }
        if actionableFloor != .low {
            rules.append(QuestionPriorityRule(
                id: "legacy_actionable_floor",
                priority: actionableFloor,
                requiresActionable: true
            ))
        }
        if !mediumPriorityTypes.isEmpty {
            rules.append(QuestionPriorityRule(
                id: "legacy_medium_priority_type",
                priority: .medium,
                questionTypes: mediumPriorityTypes
            ))
        }
        return rules
    }
}

private extension QuestionPriority {
    var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .urgent: 3
        }
    }
}
