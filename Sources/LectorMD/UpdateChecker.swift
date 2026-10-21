import Foundation

enum AppUpdateResult: Sendable {
    case available(currentVersion: String, latestVersion: String, url: URL)
    case upToDate(currentVersion: String)
    case noPublishedRelease
}

enum AppUpdateError: LocalizedError, Sendable {
    case invalidResponse
    case invalidRelease
    case unsupportedVersion
    case rateLimited
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub devolvió una respuesta que Lector MD no pudo leer. Inténtalo de nuevo más tarde."
        case .invalidRelease:
            return "La información de la versión publicada no es válida."
        case .unsupportedVersion:
            return "No se pudo comparar el formato de versión publicado con el de esta app."
        case .rateLimited:
            return "GitHub limitó las consultas por un momento. Espera un poco y vuelve a intentarlo."
        case .httpStatus(let status):
            return "GitHub respondió con el estado HTTP \(status). Inténtalo de nuevo más tarde."
        }
    }
}

enum AppUpdateChecker {
    static let repositoryURL = URL(string: "https://github.com/United2204/lector-md")!
    static let releasesURL = URL(string: "https://github.com/United2204/lector-md/releases")!

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/United2204/lector-md/releases/latest")!

    private struct GitHubRelease: Decodable, Sendable {
        let htmlURL: String
        let tagName: String
        let name: String?

        enum CodingKeys: String, CodingKey {
            case htmlURL = "html_url"
            case tagName = "tag_name"
            case name
        }
    }

    static func check() async throws -> AppUpdateResult {
        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LectorMD", forHTTPHeaderField: "User-Agent")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AppUpdateError.invalidResponse
        }

        switch response.statusCode {
        case 200:
            break
        case 404:
            return .noPublishedRelease
        case 403, 429:
            throw AppUpdateError.rateLimited
        default:
            throw AppUpdateError.httpStatus(response.statusCode)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let releaseURL = URL(string: release.htmlURL),
              releaseURL.scheme == "https",
              releaseURL.host == "github.com",
              let latestVersion = NumericVersion(release.tagName) else {
            throw AppUpdateError.invalidRelease
        }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
        guard let installedVersion = NumericVersion(currentVersion) else {
            throw AppUpdateError.unsupportedVersion
        }

        guard latestVersion > installedVersion else {
            return .upToDate(currentVersion: currentVersion)
        }
        return .available(
            currentVersion: currentVersion,
            latestVersion: release.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? release.tagName,
            url: releaseURL
        )
    }
}

private struct NumericVersion: Comparable {
    private let major: Int
    private let minor: Int
    private let patch: Int

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        value = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        guard !value.contains("-") else { return nil }

        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        let numbers = components.compactMap { Int($0) }
        guard numbers.count == components.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }

        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    static func < (lhs: NumericVersion, rhs: NumericVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
