import Foundation
import HermesCore

/// What a person can do about a failure, not the failure itself.
enum ErrorMessage {
    static func of(_ error: Error) -> String {
        if let error = error as? SignInError {
            switch error {
            case .refused(_, let description):
                return description ?? "The identity provider refused the sign-in."
            case .stateMismatch:
                return "The browser came back with another sign-in. Try again."
            case .notNeeded:
                return "This dashboard does not ask for a sign-in."
            }
        }
        if let error = error as? SessionError, error == .signInRequired {
            return "The sign-in is over. Sign in again."
        }
        if let error = error as? DashboardError {
            if error.providerUnavailable {
                return "The dashboard cannot reach its identity provider right now. Try again in a moment."
            }
            return error.detail
        }
        if let error = error as? LoopbackError {
            switch error {
            case .timedOut:
                return "The browser did not come back. Try again."
            case .cancelled:
                return "The sign-in was cancelled."
            case .socket(let code):
                return "The sign-in could not listen on the loopback address (error \(code))."
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                return "No dashboard answers at that address."
            case .notConnectedToInternet:
                return "This Mac is not connected to the network."
            case .timedOut:
                return "The dashboard did not answer in time."
            default:
                return error.localizedDescription
            }
        }
        if error is DecodingError {
            return "The dashboard answered something this client does not understand."
        }
        return error.localizedDescription
    }
}
