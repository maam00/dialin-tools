import Foundation

/// Access only on the Bluetooth queue. A delayed timeout may consume its own operation,
/// never a later operation for the same characteristic.
struct BLERequestRegistry<Value> {
    private struct Entry { var token: UUID; var value: Value }
    private var entries: [String: Entry] = [:]

    mutating func insert(_ value: Value, for key: String) -> (token: UUID, previous: Value?) {
        let token = UUID()
        let previous = entries.updateValue(Entry(token: token, value: value), forKey: key)?.value
        return (token, previous)
    }

    mutating func take(_ key: String, token: UUID? = nil) -> Value? {
        guard let entry = entries[key], token == nil || entry.token == token else { return nil }
        return entries.removeValue(forKey: key)?.value
    }

    mutating func takeAll() -> [Value] {
        let values = entries.values.map(\.value)
        entries.removeAll()
        return values
    }
}
