// Resolve MAC address and device name of BLE device from SQLite database at /Library/Bluetooth introduced in Monterey.

import SQLite3

private var inited = false
private var db_paired: OpaquePointer?
private var db_other: OpaquePointer?

// sqlite3_bind_text takes a destructor argument; SQLITE_TRANSIENT makes SQLite
// copy the value. The C macro casts to a function pointer so it isn't imported
// into Swift — build the equivalent value manually under a distinct name.
private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func connect() {
    if inited { return }

    // Read-only: we never write, and this avoids creating empty DB files or
    // taking locks on the system Bluetooth databases.
    if sqlite3_open_v2("/Library/Bluetooth/com.apple.MobileBluetooth.ledevices.paired.db", &db_paired, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
        print("paired.db open success")
    } else {
        db_paired = nil
    }

    if sqlite3_open_v2("/Library/Bluetooth/com.apple.MobileBluetooth.ledevices.other.db", &db_other, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
        print("other.db open success")
    } else {
        db_other = nil
    }

    inited = true
}

struct LEDeviceInfo {
    var name: String?
    var macAddr: String?
}

private func getStringFromRow(stmt: OpaquePointer?, index: Int32) -> String? {
    if sqlite3_column_type(stmt, index) != SQLITE_TEXT { return nil }
    let s = String(cString: sqlite3_column_text(stmt, index))
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed == "" { return nil }
    return trimmed
}

// Shared lookup body. The statement is always finalized (see defer), so
// repeated lookups don't leak sqlite3_stmt handles.
private func queryDevice(db: OpaquePointer, sql: String, uuid: String, resolvedAddressIndex: Int32?) -> LEDeviceInfo? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
        print("failed to prepare")
        return nil
    }
    defer { _ = sqlite3_finalize(s) }
    guard sqlite3_bind_text(s, 1, uuid, -1, transientDestructor) == SQLITE_OK else { return nil }
    guard sqlite3_step(s) == SQLITE_ROW else { return nil }
    let name = getStringFromRow(stmt: s, index: 0)
    let address = getStringFromRow(stmt: s, index: 1)
    var resolvedAddress: String? = nil
    if let idx = resolvedAddressIndex {
        resolvedAddress = getStringFromRow(stmt: s, index: idx)
    }
    var mac: String? = nil
    if let addr = resolvedAddress ?? address {
        // It's like "Public XX:XX:..." or "Random XX:XX:...", so split by space and take the second one
        let parts = addr.split(separator: " ")
        if parts.count > 1 {
            mac = String(parts[1])
        }
    }
    return LEDeviceInfo(name: name, macAddr: mac)
}

private func getPairedDeviceFromUUID(_ uuid: String) -> LEDeviceInfo? {
    guard let db = db_paired else { return nil }
    return queryDevice(db: db, sql: "SELECT Name, Address, ResolvedAddress FROM PairedDevices WHERE Uuid = ?", uuid: uuid, resolvedAddressIndex: 2)
}

private func getOtherDeviceFromUUID(_ uuid: String) -> LEDeviceInfo? {
    guard let db = db_other else { return nil }
    return queryDevice(db: db, sql: "SELECT Name, Address FROM OtherDevices WHERE Uuid = ?", uuid: uuid, resolvedAddressIndex: nil)
}

func getLEDeviceInfoFromUUID(_ uuid: String) -> LEDeviceInfo? {
    connect()
    return getPairedDeviceFromUUID(uuid) ?? getOtherDeviceFromUUID(uuid);
}
