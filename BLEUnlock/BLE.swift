import Foundation
import CoreBluetooth

let DeviceInformation = CBUUID(string:"180A")
let ManufacturerName = CBUUID(string:"2A29")
let ModelName = CBUUID(string:"2A24")
let ExposureNotification = CBUUID(string:"FD6F")

private var cachedBluetoothPlist: NSDictionary?
private var cachedBluetoothPlistMtime: Date?

/// The system Bluetooth plist is re-read on every device lookup; cache it in
/// memory and only re-read when the file actually changed.
func bluetoothPlist() -> NSDictionary? {
    let path = "/Library/Preferences/com.apple.Bluetooth.plist"
    let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    if let m = mtime, let cached = cachedBluetoothPlist, cachedBluetoothPlistMtime == m {
        return cached
    }
    guard let plist = NSDictionary(contentsOfFile: path) else { return nil }
    cachedBluetoothPlist = plist
    cachedBluetoothPlistMtime = mtime
    return plist
}

func getMACFromUUID(_ uuid: String) -> String? {
    guard let plist = bluetoothPlist() else { return nil }
    guard let cbcache = plist["CoreBluetoothCache"] as? NSDictionary else { return nil }
    guard let device = cbcache[uuid] as? NSDictionary else { return nil }
    return device["DeviceAddress"] as? String
}

func getNameFromMAC(_ mac: String) -> String? {
    guard let plist = bluetoothPlist() else { return nil }
    guard let devcache = plist["DeviceCache"] as? NSDictionary else { return nil }
    guard let device = devcache[mac] as? NSDictionary else { return nil }
    if let name = device["Name"] as? String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed == "" { return nil }
        return trimmed
    }
    return nil
}

class Device: NSObject {
    let uuid : UUID!
    var peripheral : CBPeripheral?
    var manufacture : String?
    var model : String?
    var advData: Data?
    var rssi: Int = 0
    var scanTimer: Timer?
    var macAddr: String?
    var blName: String?
    // Advertised TxPower (dBm) when the peripheral includes it; enables the
    // display-only distance estimate. Nil when unknown.
    var txPower: Int?
    // Outstanding DeviceInformation reads; when it drains to zero the GATT
    // connection has served its purpose and can be dropped (see BLE).
    var pendingInfoReads = 0
    // Set after the first (expensive) name/MAC resolution attempt so
    // description doesn't re-read the Bluetooth plist / SQLite DBs on every
    // advertisement. Device lifetime is bounded by the scan eviction timer,
    // so entries are re-resolved when rediscovered.
    var resolvedDeviceInfo = false
    
    override var description: String {
        get {
            // Resolve Bluetooth names/MACs only once per device. description is
            // evaluated on every advertisement, and the lookups below hit the
            // filesystem (plist + SQLite). The cached values are used below.
            if !resolvedDeviceInfo {
                resolvedDeviceInfo = true
                if macAddr == nil || blName == nil {
                    if let info = getLEDeviceInfoFromUUID(uuid.description) {
                        blName = info.name
                        macAddr = info.macAddr
                    }
                }
                if macAddr == nil {
                    macAddr = getMACFromUUID(uuid.description)
                }
                if let mac = macAddr, blName == nil {
                    blName = getNameFromMAC(mac)
                }
            }
            if macAddr != nil, let name = blName {
                // If it's just "iPhone" or "iPad", there's a chance we can get the model name in the following code
                if name != "iPhone" && name != "iPad" {
                    return name
                }
            }
            if let manu = manufacture {
                if let mod = model {
                    if manu == "Apple Inc." && appleDeviceNames[mod] != nil {
                        return appleDeviceNames[mod]!
                    }
                    return String(format: "%@/%@", manu, mod)
                } else {
                    return manu
                }
            }
            if let name = peripheral?.name {
                if name.trimmingCharacters(in: .whitespaces).count != 0 {
                    return name
                }
            }
            if let mod = model {
                return mod
            }
            // iBeacon
            if let adv = advData {
                if adv.count >= 25 {
                    var iBeaconPrefix : [uint16] = [0x004c, 0x01502]
                    if adv[0...3] == Data(bytes: &iBeaconPrefix, count: 4) {
                        let major = uint16(adv[20]) << 8 | uint16(adv[21])
                        let minor = uint16(adv[22]) << 8 | uint16(adv[23])
                        let tx = Int8(bitPattern: adv[24])
                        let distance = pow(10, Double(Int(tx) - rssi)/20.0)
                        let d = String(format:"%.1f", distance)
                        return "iBeacon [\(major), \(minor)] \(d)m"
                    }
                }
            }
            if let name = blName {
                return name
            }
            if let mac = macAddr {
                return mac // better than uuid
            }
            return uuid.description
        }
    }

    init(uuid _uuid: UUID) {
        uuid = _uuid
    }
}

protocol BLEDelegate {
    func newDevice(device: Device)
    func updateDevice(device: Device)
    func removeDevice(device: Device)
    func updateRSSI(rssi: Int?, active: Bool, distance: Double?)
    func updatePresence(presence: Bool, reason: String)
    func bluetoothPowerWarn()
    func calibrationDidFinish(baseRSSI: Int?)
}

class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let UNLOCK_DISABLED = 1
    let LOCK_DISABLED = -100
    var centralMgr : CBCentralManager!
    var devices : [UUID : Device] = [:]
    var delegate: BLEDelegate?
    var scanMode = false
    var monitoredUUID: UUID?
    var monitoredPeripheral: CBPeripheral?
    var proximityTimer : Timer?
    var signalTimer: Timer?
    var presence = false
    var lockRSSI = -80
    var unlockRSSI = -60
    /// Effective thresholds: the globals shifted by the monitored device's
    /// 1m calibration (0 when uncalibrated), so one dBm setting means the
    /// same physical distance across devices.
    var unlockThreshold: Int {
        (unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI) + calibratedOffset
    }
    var lockThreshold: Int {
        (lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI) + calibratedOffset
    }
    var proximityTimeout = 5.0
    var signalTimeout = 60.0
    var lastReadAt = 0.0
    var powerWarn = true
    var passiveMode = false
    var thresholdRSSI = -70
    var rssiFilter = RSSIFilter()
    var lastEstimatedRSSI: Int? = nil
    // Throttle for updateRSSI: the menu title is the only consumer.
    var lastReportedRSSI: Int? = nil
    var lastReportedActive = false
    var lastReportAt = 0.0
    var monitoredTxPower: Int? = nil
    var lastDistance: Double? = nil
    // Per-device 1m calibration: the global dBm thresholds shift by this
    // offset (measured@1m minus the -59dBm reference). 0 when uncalibrated.
    var calibratedOffset = 0
    let calibrationReferenceRSSI = -59
    var calibrating = false
    var calibrationSamples: [Int] = []
    var calibrationTimer: Timer?
    let calibrationDuration = 8.0
    var activeModeTimer : Timer? = nil
    var connectionTimer : Timer? = nil

    func scanForPeripherals() {
        guard !centralMgr.isScanning else { return }
        centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        //print("Start scanning")
    }

    func startScanning() {
        scanMode = true
        scanForPeripherals()
    }

    func stopScanning() {
        scanMode = false
        // In passive monitoring the scan must keep running to track the
        // device; otherwise stop it — an idle duplicates scan with no
        // monitored device is pure battery drain (e.g. menu opened once
        // on a fresh install with nothing selected).
        if activeModeTimer != nil || monitoredUUID == nil {
            centralMgr.stopScan()
        }
    }

    func setPassiveMode(_ mode: Bool) {
        passiveMode = mode
        if passiveMode {
            activeModeTimer?.invalidate()
            activeModeTimer = nil
            if let p = monitoredPeripheral {
                centralMgr.cancelPeripheralConnection(p)
            }
        }
        scanForPeripherals()
    }

    func startMonitor(uuid: UUID) {
        if let p = monitoredPeripheral {
            centralMgr.cancelPeripheralConnection(p)
        }
        monitoredUUID = uuid
        proximityTimer?.invalidate()
        resetSignalTimer()
        presence = true
        monitoredPeripheral = nil
        activeModeTimer?.invalidate()
        activeModeTimer = nil
        // Drop smoothing/report state from any previously monitored device.
        rssiFilter.reset()
        lastEstimatedRSSI = nil
        lastReportedRSSI = nil
        cancelCalibration()
        calibratedOffset = 0
        monitoredTxPower = nil
        lastDistance = nil
        scanForPeripherals()
    }

    func resetSignalTimer() {
        // Advertisements arrive at ~10Hz; recreating a 60s timer on every
        // one is pure churn. Reuse the armed timer unless it's more than
        // half elapsed — "lost" is still declared within ~60s of silence.
        if let timer = signalTimer, timer.isValid,
           timer.fireDate.timeIntervalSinceNow > signalTimeout / 2 {
            return
        }
        signalTimer?.invalidate()
        signalTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            print("Device is lost")
            self.lastReportedRSSI = nil
            self.delegate?.updateRSSI(rssi: nil, active: false, distance: nil)
            if self.presence {
                self.presence = false
                self.delegate?.updatePresence(presence: self.presence, reason: "lost")
            }
        })
        if let timer = signalTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth powered on")
            if activeModeTimer == nil {
                scanForPeripherals()
            }
            powerWarn = false
        case .poweredOff:
            print("Bluetooth powered off")
            presence = false
            signalTimer?.invalidate()
            signalTimer = nil
            // Sync the menu out of its stale connected state. Deliberately
            // not a presence event: toggling Bluetooth off must not lock.
            lastReportedRSSI = nil
            delegate?.updateRSSI(rssi: nil, active: false, distance: nil)
            if powerWarn {
                powerWarn = false
                delegate?.bluetoothPowerWarn()
            }
        default:
            break
        }
    }
    
    func reportRSSI(_ estimatedRSSI: Int, active: Bool, distance: Double?, now: Double) {
        // The menu title is the only consumer; refreshing it on every
        // advertisement (~10Hz) churns AppKit for no visible benefit.
        // Report on mode change, on movement >= 2dB, or at least once a second.
        if active == lastReportedActive, let last = lastReportedRSSI,
           abs(estimatedRSSI - last) < 2, now - lastReportAt < 1.0 {
            return
        }
        lastReportedRSSI = estimatedRSSI
        lastReportedActive = active
        lastReportAt = now
        delegate?.updateRSSI(rssi: estimatedRSSI, active: active, distance: distance)
    }

    func beginCalibration() {
        // Collect raw valid samples for a fixed window, then report their
        // mean as "RSSI at 1m". Stand 1m from the Mac while this runs.
        guard monitoredUUID != nil else { return }
        cancelCalibration()
        calibrating = true
        calibrationTimer = Timer.scheduledTimer(withTimeInterval: calibrationDuration, repeats: false, block: { [weak self] _ in
            self?.finishCalibration()
        })
        if let timer = calibrationTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func cancelCalibration() {
        calibrationTimer?.invalidate()
        calibrationTimer = nil
        calibrating = false
        calibrationSamples = []
    }

    func finishCalibration() {
        calibrationTimer = nil
        calibrating = false
        let samples = calibrationSamples
        calibrationSamples = []
        guard samples.count >= 3 else {
            delegate?.calibrationDidFinish(baseRSSI: nil)
            return
        }
        let mean = Int(Double(samples.reduce(0, +)) / Double(samples.count))
        // Sanity: at a true 1m no phone/watch reads hotter than -50dBm or
        // weaker than -80dBm. Outside that the user stood too close/far, and
        // accepting it would shift thresholds into unreachable territory
        // (an unlock level that can never fire) with zero feedback.
        guard (-80 ... -50).contains(mean) else {
            delegate?.calibrationDidFinish(baseRSSI: nil)
            return
        }
        delegate?.calibrationDidFinish(baseRSSI: mean)
    }

    func updateMonitoredPeripheral(_ rssi: Int) {
        // Invalid samples (hardware glitches) must not move the filter or
        // extend presence. Callers pre-validate; this is defense in depth.
        guard RSSIFilter.isValidSample(rssi) else { return }
        let now = Date().timeIntervalSince1970

        let estimatedRSSI = rssiFilter.addSample(rssi, at: now)
        lastEstimatedRSSI = estimatedRSSI
        if calibrating {
            calibrationSamples.append(rssi)
        }
        if let tx = monitoredTxPower {
            lastDistance = RSSIFilter.distance(txPower: tx, rssi: estimatedRSSI)
        } else {
            lastDistance = nil
        }
        reportRSSI(estimatedRSSI, active: activeModeTimer != nil, distance: lastDistance, now: now)

        // Both directions use the *filtered* value: unlocking on a single raw
        // spike while locking on the average caused flapping at the boundary.
        if estimatedRSSI >= unlockThreshold && !presence {
            print("Device is close")
            presence = true
            delegate?.updatePresence(presence: presence, reason: "close")
        }

        if estimatedRSSI >= lockThreshold {
            if let timer = proximityTimer {
                timer.invalidate()
                print("Proximity timer canceled")
                proximityTimer = nil
            }
        } else if presence && proximityTimer == nil {
            proximityTimer = Timer.scheduledTimer(withTimeInterval: proximityTimeout, repeats: false, block: { [weak self] _ in
                guard let self = self else { return }
                print("Device is away")
                self.presence = false
                self.delegate?.updatePresence(presence: self.presence, reason: "away")
                self.proximityTimer = nil
            })
            RunLoop.main.add(proximityTimer!, forMode: .common)
            print("Proximity timer started")
        }
        resetSignalTimer()
    }

    func evictDevice(_ device: Device) {
        delegate?.removeDevice(device: device)
        if let p = device.peripheral {
            centralMgr.cancelPeripheralConnection(p)
        }
        device.scanTimer?.invalidate()
        device.scanTimer = nil
        devices.removeValue(forKey: device.uuid)
    }

    func resetScanTimer(device: Device) {
        // Same churn avoidance as resetSignalTimer: advertisements arrive
        // continuously, so keep the armed eviction timer while it's fresh.
        if let timer = device.scanTimer, timer.isValid,
           timer.fireDate.timeIntervalSinceNow > signalTimeout / 2 {
            return
        }
        device.scanTimer?.invalidate()
        // Weak captures: the run loop retains the timer and the device retains
        // the timer, so strong captures would pin both until firing.
        device.scanTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { [weak self, weak device] _ in
            guard let self = self, let device = device else { return }
            self.evictDevice(device)
        })
        if let timer = device.scanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func connectMonitoredPeripheral() {
        guard let p = monitoredPeripheral else { return }

        // Idk why but this works like a charm when 'didConnect' won't get called.
        // However, this generates warnings in the log.
        p.readRSSI()

        guard p.state == .disconnected else { return }
        print("Connecting")
        centralMgr.connect(p, options: nil)
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false, block: { [weak self, weak p] _ in
            guard let self = self, let p = p else { return }
            if p.state == .connecting {
                print("Connection timeout")
                self.centralMgr.cancelPeripheralConnection(p)
            }
        })
        RunLoop.main.add(connectionTimer!, forMode: .common)
    }

    func txPower(from advertisementData: [String : Any]) -> Int? {
        guard let tx = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber,
              RSSIFilter.validTxPowerRange.contains(tx.intValue) else { return nil }
        return tx.intValue
    }

    //MARK:- CBCentralManagerDelegate start

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        let rawRSSI = RSSI.intValue
        let rssiValid = RSSIFilter.isValidSample(rawRSSI)
        if let uuid = monitoredUUID {
            if peripheral.identifier == uuid {
                // Refresh: CoreBluetooth may hand out a new instance for a
                // returning device; active polling and RSSI guards track this
                // reference, so a stale one would silently drop updates.
                monitoredPeripheral = peripheral
                if let tx = txPower(from: advertisementData) {
                    monitoredTxPower = tx
                }
                if activeModeTimer == nil && rssiValid {
                    //print("Discover \(rawRSSI)dBm")
                    updateMonitoredPeripheral(rawRSSI)
                    if !passiveMode {
                        connectMonitoredPeripheral()
                    }
                }
            }
        }

        if (scanMode) {
            if let uuids = advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID] {
                for uuid in uuids {
                    if uuid == ExposureNotification {
                        //print("Device \(peripheral.identifier) Exposure Notification")
                        return
                    }
                }
            }
            if let device = devices[peripheral.identifier] {
                // Duplicate advertisements arrive continuously; the menu title
                // only shows the RSSI, so skip the (expensive) UI refresh when
                // nothing changed. The eviction timer is still reset below.
                if let tx = txPower(from: advertisementData) {
                    device.txPower = tx
                }
                if rssiValid && device.rssi != rawRSSI {
                    device.rssi = rawRSSI
                    delegate?.updateDevice(device: device)
                }
                // Prune far-away devices early (10dB hysteresis below the
                // listing threshold) instead of holding a GATT connection
                // until the 60s eviction timer fires. Never prune the
                // monitored peripheral's own connection.
                if rssiValid && rawRSSI < thresholdRSSI - 10 && device.peripheral !== monitoredPeripheral {
                    evictDevice(device)
                } else {
                    resetScanTimer(device: device)
                }
            } else if rssiValid && rawRSSI >= thresholdRSSI {
                // Bogus readings (e.g. positive values some stacks report on
                // error) must not pass the threshold gate or pollute the list.
                let device = Device(uuid: peripheral.identifier)
                device.peripheral = peripheral
                device.rssi = rawRSSI
                device.txPower = txPower(from: advertisementData)
                device.advData = advertisementData["kCBAdvDataManufacturerData"] as? Data
                devices[peripheral.identifier] = device
                central.connect(peripheral, options: nil)
                delegate?.newDevice(device: device)
                resetScanTimer(device: device)
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral)
    {
        peripheral.delegate = self
        if scanMode {
            peripheral.discoverServices([DeviceInformation])
        }
        if peripheral == monitoredPeripheral && !passiveMode {
            print("Connected")
            connectionTimer?.invalidate()
            connectionTimer = nil
            peripheral.readRSSI()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?)
    {
        // Recovery is already covered (the active poll tick or the next
        // advertisement reconnects); log so failures aren't silent.
        print("Failed to connect to \(peripheral.identifier): \(error?.localizedDescription ?? "unknown error")")
    }

    //MARK:CBCentralManagerDelegate end -
    
    //MARK:- CBPeripheralDelegate start

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard peripheral == monitoredPeripheral else { return }
        // On error the value is garbage; feeding it to the filter would
        // swing the estimate and flap presence.
        guard error == nil, RSSIFilter.isValidSample(RSSI.intValue) else { return }
        let rssi = RSSI.intValue
        //print("readRSSI \(rssi)dBm")
        updateMonitoredPeripheral(rssi)
        lastReadAt = Date().timeIntervalSince1970

        if activeModeTimer == nil && !passiveMode {
            print("Entering active mode")
            if !scanMode {
                centralMgr.stopScan()
            }
            scheduleActivePoll()
        }
    }

    /// Poll fast near a lock/unlock decision boundary, slow when far away to
    /// save radio/power. Fixed 2s polling was both wasteful (far) and slow
    /// (at the boundary).
    func activePollInterval() -> TimeInterval {
        // Calibrating? Sample fast regardless of margins to gather enough data.
        if calibrating { return 1.0 }
        guard let estimated = lastEstimatedRSSI else { return 2.0 }
        let margin = min(abs(estimated - unlockThreshold), abs(estimated - lockThreshold))
        if margin <= 5 { return 1.0 }
        if margin <= 10 { return 2.0 }
        return 5.0
    }

    func scheduleActivePoll() {
        activeModeTimer?.invalidate()
        activeModeTimer = Timer.scheduledTimer(withTimeInterval: activePollInterval(), repeats: false, block: { [weak self] timer in
            guard let self = self else { return }
            guard let peripheral = self.monitoredPeripheral else {
                timer.invalidate()
                self.activeModeTimer = nil
                self.scanForPeripherals()
                return
            }
            if Date().timeIntervalSince1970 > self.lastReadAt + 10 {
                print("Falling back to passive mode")
                self.centralMgr.cancelPeripheralConnection(peripheral)
                self.activeModeTimer?.invalidate()
                self.activeModeTimer = nil
                self.scanForPeripherals()
            } else if peripheral.state == .connected {
                peripheral.readRSSI()
                self.scheduleActivePoll()
            } else {
                self.connectMonitoredPeripheral()
                self.scheduleActivePoll()
            }
        })
        if let timer = activeModeTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard error == nil else {
            centralMgr.cancelPeripheralConnection(peripheral)
            return
        }
        var found = false
        if let services = peripheral.services {
            for service in services {
                if service.uuid == DeviceInformation {
                    found = true
                    peripheral.discoverCharacteristics([ManufacturerName, ModelName], for: service)
                }
            }
        }
        // No DeviceInformation service: nothing more to learn from this
        // device, so don't hold a GATT connection open until eviction.
        // The monitored peripheral is exempt — its connection is managed
        // by the active/passive polling logic.
        if !found && peripheral !== monitoredPeripheral {
            centralMgr.cancelPeripheralConnection(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?)
    {
        guard error == nil else {
            if peripheral !== monitoredPeripheral {
                centralMgr.cancelPeripheralConnection(peripheral)
            }
            return
        }
        // Count the reads we're about to issue so didUpdateValueFor knows
        // when everything learnable has arrived and can drop the connection.
        // (Waiting for "both values non-nil" instead would strand devices
        // that expose only one of the two characteristics.)
        var wanted = 0
        if let chars = service.characteristics {
            for chara in chars {
                if chara.uuid == ManufacturerName || chara.uuid == ModelName {
                    wanted += 1
                    peripheral.readValue(for:chara)
                }
            }
        }
        if let device = devices[peripheral.identifier] {
            device.pendingInfoReads = wanted
        }
        if wanted == 0 && peripheral !== monitoredPeripheral {
            centralMgr.cancelPeripheralConnection(peripheral)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?)
    {
        guard characteristic.uuid == ManufacturerName || characteristic.uuid == ModelName else { return }
        guard let device = devices[peripheral.identifier] else { return }
        device.pendingInfoReads -= 1
        if let value = characteristic.value {
            let str: String? = String(data: value, encoding: .utf8)
            if let s = str {
                if characteristic.uuid == ManufacturerName {
                    device.manufacture = s
                    delegate?.updateDevice(device: device)
                }
                if characteristic.uuid == ModelName {
                    device.model = s
                    delegate?.updateDevice(device: device)
                }
            }
        }
        if device.pendingInfoReads <= 0 && device.peripheral !== monitoredPeripheral {
            centralMgr.cancelPeripheralConnection(peripheral)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didModifyServices invalidatedServices: [CBService])
    {
        peripheral.discoverServices([DeviceInformation])
    }
    //MARK:CBPeripheralDelegate end -

    override init() {
        super.init()
        centralMgr = CBCentralManager(delegate: self, queue: nil)
    }
}
