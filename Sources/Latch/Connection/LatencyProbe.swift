//
//  LatencyProbe.swift
//  Latch
//
//  SPEC §9.1 : la barre d'état basse montre aussi la latence.
//
//  On mesure le temps d'établissement d'une connexion TCP vers le port ssh de
//  l'hôte. C'est un aller-retour réseau réel, sans privilège particulier — un
//  ping ICMP demanderait un socket brut — et sans rien envoyer sur la session
//  de travail, qu'on ne veut pas perturber pour afficher un chiffre.
//

import Foundation
import Network

@MainActor
final class LatencyProbe: ObservableObject {

    /// Le dernier aller-retour mesuré. `nil` tant qu'on ne sait pas.
    @Published private(set) var roundTrip: Duration?

    private let host: String
    private let port: UInt16
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(host: String, port: UInt16 = 22, interval: Duration = .seconds(10)) {
        self.host = host
        self.port = port
        self.interval = interval
    }

    deinit {
        task?.cancel()
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let measured = await Self.measure(host: self.host, port: self.port)
                guard !Task.isCancelled else { return }
                self.roundTrip = measured
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        roundTrip = nil
    }

    /// « 12 ms », ou rien. Une latence qu'on ne connaît pas ne s'affiche pas :
    /// mieux vaut un vide qu'un zéro qui ment.
    var label: String? {
        guard let roundTrip else { return nil }
        let milliseconds = Double(roundTrip.components.attoseconds) / 1e15
            + Double(roundTrip.components.seconds) * 1000
        return milliseconds < 1
            ? "<1 ms"
            : String(format: "%.0f ms", milliseconds)
    }

    // MARK: - Mesure

    nonisolated static func measure(
        host: String, port: UInt16, timeout: Duration = .seconds(5)
    ) async -> Duration? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }

        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: endpointPort, using: .tcp
        )
        let started = ContinuousClock.now

        let elapsed: Duration? = await withCheckedContinuation { continuation in
            let finished = Locked(false)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if finished.exchange(true) { return }
                    continuation.resume(returning: ContinuousClock.now - started)
                case .failed, .cancelled:
                    if finished.exchange(true) { return }
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))

            Task {
                try? await Task.sleep(for: timeout)
                if finished.exchange(true) { return }
                continuation.resume(returning: nil)
            }
        }

        connection.cancel()
        return elapsed
    }
}

/// Un drapeau à bascule sûr entre files : la continuation ne doit être reprise
/// qu'une fois, et deux rappels peuvent arriver en même temps.
private final class Locked<Value>: @unchecked Sendable where Value: Equatable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    /// Rend l'ancienne valeur et pose la nouvelle, en une seule opération.
    func exchange(_ new: Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}
