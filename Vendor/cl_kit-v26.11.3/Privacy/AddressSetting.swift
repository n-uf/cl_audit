// AddressDefaultsStore: an OPTIONAL convenience for an app (or several of its processes) that keeps its "Blur addresses"
// setting in a prefs domain and announces changes with a distributed notification (an app whose several processes all read
// one domain and reload on one note). The module never picks a domain or a key itself: the
// app names them, so two apps never share a setting. An app that stores the setting some other way ignores this file and
// calls `AddressPrivacy.shared.apply(blur:)`.

import Foundation

/// Where the booleans live: UserDefaults (any suite) conforms; a check passes a dictionary of its own.
public protocol AddressPrefs: AnyObject {
    func addressBool(_ key: String) -> Bool?
    func setAddressBool(_ value: Bool, _ key: String)
    func removeAddressKey(_ key: String)
}

extension UserDefaults: AddressPrefs {
    public func addressBool(_ key: String) -> Bool? { object(forKey: key) as? Bool }
    public func setAddressBool(_ value: Bool, _ key: String) { set(value, forKey: key) }
    public func removeAddressKey(_ key: String) { removeObject(forKey: key) }
}

/// The setting in a prefs domain.
///   - `suite`: the domain (nil: the app's own standard defaults), or pass `prefs` yourself.
///   - `key`: the key; `valueMeansShown` says which way it reads (a key like `showEmails`: true = shown, so addresses are
///     blurred when it is false or missing; a key of the other sense, "blur", leaves it false).
///   - `legacyKey`: an older key of the other sense (like `blurEmails`, true = blurred): read when `key` is missing, and
///     removed on the next write.
///   - `changeNote`: the distributed notification the setting's writers post and its readers reload on (the app names it).
///     Writing through this store posts it.
/// A missing setting means the blur is ON.
public final class AddressDefaultsStore: AddressBlurStore {
    private let prefs: AddressPrefs
    private let key: String
    private let valueMeansShown: Bool
    private let legacyKey: String?
    private let legacyMeansShown: Bool
    private let changeNote: Notification.Name?
    private var observer: NSObjectProtocol?

    public init(suite: String? = nil, key: String, valueMeansShown: Bool = false,
                legacyKey: String? = nil, legacyValueMeansShown: Bool = false,
                changeNote: String? = nil, prefs: AddressPrefs? = nil) {
        self.prefs = prefs ?? suite.flatMap { UserDefaults(suiteName: $0) } ?? UserDefaults.standard
        self.key = key; self.valueMeansShown = valueMeansShown
        self.legacyKey = legacyKey; self.legacyMeansShown = legacyValueMeansShown
        self.changeNote = changeNote.map { Notification.Name(rawValue: $0) }
    }
    deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) } }

    /// Whether addresses are blurred, as the domain says now (read each time, so a draw in a process that listens for
    /// nothing, a Dock plug-in, always has the current value).
    public var blurAddresses: Bool {
        get {
            if let v = prefs.addressBool(key) { return valueMeansShown ? !v : v }
            if let legacyKey, let v = prefs.addressBool(legacyKey) { return legacyMeansShown ? !v : v }
            return true
        }
        set {
            prefs.setAddressBool(valueMeansShown ? !newValue : newValue, key)
            if let legacyKey { prefs.removeAddressKey(legacyKey) }
            if let changeNote { DistributedNotificationCenter.default().postNotificationName(changeNote, object: nil, userInfo: nil, deliverImmediately: true) }
        }
    }

    /// Hands the setting to `privacy` now, and again whenever the change note arrives (from this process or another).
    public func observe(_ privacy: AddressPrivacy = .shared) {
        privacy.apply(blur: blurAddresses)
        guard let changeNote else { return }
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = DistributedNotificationCenter.default().addObserver(forName: changeNote, object: nil, queue: .main) { [weak self, weak privacy] _ in
            guard let self, let privacy else { return }
            privacy.apply(blur: self.blurAddresses)
        }
    }
}
