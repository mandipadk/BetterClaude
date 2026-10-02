import CoworkKit
import Foundation
import Observation

/// Every account's plan limits and what used them, kept current while the app runs.
@MainActor
@Observable
final class UsageModel {
    private(set) var quotas: [AccountQuota] = []
    /// What used each account's current week, heaviest first, by account id.
    private(set) var spend: [String: [QuotaAttribution.Item]] = [:]
    private(set) var loaded = false

    private var task: Task<Void, Never>?
    private var timer: Timer?

    /// Claude writes a reading every quarter of an hour or so; looking every five minutes
    /// keeps the page current without reading anything more often than it changes.
    func start(_ services: AppServices) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self, weak services] _ in
            MainActor.assumeIsolated {
                guard let self, let services else { return }
                self.refresh(snapshot: services.snapshot, index: services.index.index)
            }
        }
    }

    func refresh(snapshot: CatalogSnapshot, index: HistoryIndex?) {
        task?.cancel()
        task = Task {
            let quotas = await Task.detached(priority: .utility) { QuotaReader.accounts(in: snapshot) }.value
            guard !Task.isCancelled else { return }
            var spend: [String: [QuotaAttribution.Item]] = [:]
            if let index {
                for quota in quotas {
                    let since = quota.weekStart ?? Date().addingTimeInterval(-7 * 86_400)
                    spend[quota.account.id] = (try? await QuotaAttribution.items(
                        index: index, accountIDs: [quota.account.id], since: since)) ?? []
                }
            }
            guard !Task.isCancelled else { return }
            self.quotas = quotas
            self.spend = spend
            loaded = true
            alert(quotas)
        }
    }

    /// Called with each fresh reading; posts what's newly close to a limit.
    var notifier: PulseNotifier?
    private static let sentKey = "limitAlertsSent"

    private func alert(_ quotas: [AccountQuota]) {
        guard let notifier else { return }
        let defaults = UserDefaults.standard
        var sent = defaults.stringArray(forKey: Self.sentKey) ?? []
        for alert in LimitAlerts.due(quotas, alreadySent: Set(sent)) {
            notifier.post(alert)
            sent.append(alert.key)
        }
        defaults.set(Array(sent.suffix(200)), forKey: Self.sentKey)
    }

    func quota(for accountID: String?) -> AccountQuota? {
        accountID.flatMap { id in quotas.first { $0.account.id == id } }
    }

    /// How much of an account's tightest limit is left, 0 to 100: five hours, the week, or a
    /// weekly limit for one model.
    func headroom(for accountID: String?) -> Double? {
        quota(for: accountID)?.headroom
    }
}
