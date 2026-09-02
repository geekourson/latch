//
//  Keychain.swift
//  Latch
//
//  SPEC §11 : « Si un mot de passe est indispensable : lecture depuis le
//  trousseau (`kSecClassInternetPassword`) ».
//
//  Le fichier de configuration ne contient jamais de secret (§4). Quand un
//  hôte refuse obstinément les clés, le mot de passe vit ici et nulle part
//  ailleurs — pas dans le JSON, pas dans une variable d'environnement, pas sur
//  une ligne de commande.
//

import Foundation
import Security

enum Keychain {

    enum KeychainError: LocalizedError {
        case failed(status: OSStatus)

        var errorDescription: String? {
            guard case .failed(let status) = self else { return nil }
            let message = SecCopyErrorMessageString(status, nil) as String?
            return message ?? "Erreur du trousseau (\(status))."
        }
    }

    /// La requête qui identifie une entrée. `kSecAttrProtocolSSH` la range avec
    /// les autres secrets ssh du trousseau, là où l'utilisateur ira la chercher.
    private static func query(alias: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrProtocol as String: kSecAttrProtocolSSH,
            kSecAttrServer as String: alias,
            kSecAttrAccount as String: account,
        ]
    }

    static func password(alias: String, account: String) -> String? {
        var request = query(alias: alias, account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func store(_ password: String, alias: String, account: String) throws {
        let request = query(alias: alias, account: account)
        let payload = Data(password.utf8)

        // Remplacer proprement plutôt qu'empiler des doublons.
        let update = SecItemUpdate(
            request as CFDictionary, [kSecValueData as String: payload] as CFDictionary
        )
        if update == errSecSuccess { return }

        guard update == errSecItemNotFound else { throw KeychainError.failed(status: update) }

        var creation = request
        creation[kSecValueData as String] = payload
        creation[kSecAttrLabel as String] = "Latch — \(alias)"
        let status = SecItemAdd(creation as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.failed(status: status) }
    }

    @discardableResult
    static func remove(alias: String, account: String) -> Bool {
        SecItemDelete(query(alias: alias, account: account) as CFDictionary) == errSecSuccess
    }

    static func hasPassword(alias: String, account: String) -> Bool {
        var request = query(alias: alias, account: account)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }
}
