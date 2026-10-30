import Foundation

/// A provider the dashboard offers, with the models it can answer on.
public struct ModelProvider: Sendable, Equatable, Identifiable {
    public let slug: String
    public let name: String
    public let models: [String]
    public let isCurrent: Bool
    public let warning: String?

    public var id: String { slug }

    public init(slug: String, name: String, models: [String], isCurrent: Bool = false, warning: String? = nil) {
        self.slug = slug
        self.name = name
        self.models = models
        self.isCurrent = isCurrent
        self.warning = warning
    }
}

/// What `GET /api/model/options` answers: the model in use and everything it could be.
public struct ModelOptions: Sendable, Equatable {
    public let model: String?
    public let provider: String?
    public let providers: [ModelProvider]

    public init(model: String?, provider: String?, providers: [ModelProvider]) {
        self.model = model
        self.provider = provider
        self.providers = providers
    }

    public init(_ json: JSONValue) {
        model = json["model"]?.stringValue
        provider = json["provider"]?.stringValue
        providers = (json["providers"]?.arrayValue ?? []).compactMap { entry in
            let slug = entry["slug"]?.stringValue ?? ""
            guard !slug.isEmpty else { return nil }
            let models = (entry["models"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard !models.isEmpty else { return nil }
            return ModelProvider(
                slug: slug,
                name: entry["name"]?.stringValue ?? slug,
                models: models,
                isCurrent: entry["is_current"]?.boolValue ?? false,
                warning: entry["warning"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }
}

/// What the dashboard did with a model asked for.
public enum ModelChange: Sendable, Equatable {
    /// The chat answers on the new model from its next turn.
    case set
    /// A turn was running: the dashboard switches at the next one.
    case deferred(warning: String?)
    /// The model is expensive and the dashboard wants to be told twice.
    case needsConfirmation(message: String)
}
