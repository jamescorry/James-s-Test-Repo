import Toybox.Lang;
import Toybox.Timer;
using Toybox.BluetoothLowEnergy as Ble;

//! BLE transport to a Tesla.
//!
//! Framing follows Tesla's spec: every message is preceded by its length as a
//! two-byte big-endian value. Connect IQ caps a characteristic write at 20
//! bytes and permits only one outstanding write at a time, so outbound
//! messages are split into chunks and fed one at a time as each write
//! completes. Inbound notifications are reassembled until a full message has
//! arrived.
//!
//! Structure follows the BLE delegate in kaedenbrinkman/Garmin-TeslaKey (MIT) -
//! see NOTICE.
class BleTransport extends Ble.BleDelegate {
    const SERVICE_UUID = "00000211-b2d1-43f0-9b88-960cebf8b91e";
    const WRITE_CHAR_UUID = "00000212-b2d1-43f0-9b88-960cebf8b91e";
    const READ_CHAR_UUID = "00000213-b2d1-43f0-9b88-960cebf8b91e";

    //! Generic Access, present on nearly every peripheral. Its Device Name
    //! characteristic is read from devices that turn out not to carry the
    //! Tesla service, to learn what the watch actually connected to.
    const GAP_SERVICE_UUID = "00001800-0000-1000-8000-00805f9b34fb";
    const GAP_DEVICE_NAME_UUID = "00002a00-0000-1000-8000-00805f9b34fb";

    //! The Tesla service uuid as it appears on air: 128-bit uuids in an
    //! advertisement are little-endian.
    private var _teslaUuidLe as ByteArray;

    // Advertisement data types, Bluetooth Core Specification Supplement.
    private const AD_INCOMPLETE_128BIT_UUIDS = 0x06;
    private const AD_COMPLETE_128BIT_UUIDS = 0x07;
    private const AD_SHORT_NAME = 0x08;
    private const AD_COMPLETE_NAME = 0x09;

    //! Connect IQ's per-write payload limit.
    private const CHUNK_SIZE = 20;

    //! Tesla's VCSEC will not accept a message larger than this, so a claimed
    //! length beyond it means the stream has desynchronised.
    private const MAX_MESSAGE_SIZE = 1024;

    //! Do not try to connect to nameless devices weaker than this. The car you
    //! are standing next to is loud; a neighbour's doorbell is not.
    private const CANDIDATE_MIN_RSSI = -75;

    //! How long to let GATT service discovery run before deciding a connected
    //! device is not a car. On hardware the car took six to twelve seconds
    //! just to connect - it negotiates a slow link to save power - and
    //! discovery over that link is slow in proportion. Four seconds was not
    //! enough; this allows fifteen.
    private const VERIFY_INTERVAL_MS = 500;
    private const VERIFY_ATTEMPTS = 20;

    //! How long to wait for a rejected device to answer a name read before
    //! moving on without one.
    private const IDENTIFY_TIMEOUT_MS = 4000;

    private var _service as Ble.Uuid;
    private var _writeChar as Ble.Uuid;
    private var _readChar as Ble.Uuid;
    private var _gapService as Ble.Uuid;
    private var _gapDeviceName as Ble.Uuid;

    // Devices already connected to and found not to be a car. Without this
    // the scan keeps handing back the loudest of them - in a Tesla, that is
    // one of four tyre pressure sensors - and the car is never reached.
    private var _rejectedResults as Array = [];
    private var _identifying as Boolean = false;
    private var _gapRegistered as Boolean = false;
    private var _currentResult as Ble.ScanResult?;

    private var _listener;
    private var _targetName as String?;
    // Optional exact address from a BLE scanner. This is useful on Garmin
    // devices that do not expose Tesla's advertised local name, while keeping
    // VIN-derived name matching as the default for devices with stable names.
    private var _targetAddress as String?;
    private var _device as Ble.Device?;
    private var _scanning as Boolean = false;

    // Connect IQ stops scanning on its own, so wanting to scan and actually
    // scanning are different things. A car advertising slowly while parked
    // falls outside a short window entirely.
    private var _scanDesired as Boolean = false;
    private var _scanTimer as Timer.Timer;

    // A connection attempt in progress. Scanning is paused for it, and must
    // not be restarted underneath it by the keep-alive.
    private var _connecting as Boolean = false;
    private var _connected as Boolean = false;
    private var _rejected as Number = 0;
    private var _attempted as Number = 0;

    // Service discovery finishes some time after the connection reports
    // itself connected, so the GATT table has to be re-read rather than
    // trusted on the first look.
    private var _verifyTimer as Timer.Timer;
    private var _verifyAttempts as Number = 0;

    // Diagnostics: collect what the scan sees instead of connecting to it.
    private var _diagnostic as Boolean = false;
    private var _discovered as Array = [];

    // Traffic counters. "No response" cannot distinguish a car that never
    // heard us from one that replied in a shape we failed to parse.
    private var _bytesWritten as Number = 0;
    private var _bytesReceived as Number = 0;
    private var _messagesReceived as Number = 0;

    private var _rxBuffer as ByteArray = []b;
    private var _txChunks as Array = [];
    private var _writeInFlight as Boolean = false;

    function initialize(listener) {
        BleDelegate.initialize();
        _listener = listener;
        _scanTimer = new Timer.Timer();
        _verifyTimer = new Timer.Timer();
        _service = Ble.stringToUuid(SERVICE_UUID);
        _writeChar = Ble.stringToUuid(WRITE_CHAR_UUID);
        _readChar = Ble.stringToUuid(READ_CHAR_UUID);
        _gapService = Ble.stringToUuid(GAP_SERVICE_UUID);
        _gapDeviceName = Ble.stringToUuid(GAP_DEVICE_NAME_UUID);
        _teslaUuidLe = [
            0x1e, 0xb9, 0xf8, 0xeb, 0x0c, 0x96, 0x88, 0x9b,
            0xf0, 0x43, 0xd1, 0xb2, 0x11, 0x02, 0x00, 0x00
        ]b;
    }

    //! Register the Tesla GATT profile. Must be called once, before scanning,
    //! and Connect IQ allows only a small number of registered profiles.
    function open() as Void {
        Ble.setDelegate(self);
        try {
            Ble.registerProfile({
                :uuid => _service,
                :characteristics => [
                    {
                        :uuid => _readChar,
                        :descriptors => [Ble.cccdUuid()]
                    },
                    {
                        :uuid => _writeChar
                    }
                ]
            });
        } catch (ex) {
            DebugLog.add("! tesla profile: " + describe(ex));
        }

        // Generic Access is not registered. It is a system service, and
        // registering a profile for it took the app down on a Fenix 8 Pro
        // about a second after launch - not as a catchable exception, but
        // as a termination after the asynchronous registration result. A
        // single profile, as here, ran without trouble. The read path below
        // stays in place behind _gapRegistered in case a later SDK allows it.
        _gapRegistered = false;
    }

    function onProfileRegister(uuid as Ble.Uuid, status as Ble.Status) as Void {
        DebugLog.add("profile " + (status == Ble.STATUS_SUCCESS ? "ok" : "status " + status.toString()));
    }

    //! Class and message of an exception, for the log.
    private function describe(ex) as String {
        var text = "";
        if (ex has :getErrorMessage) {
            var message = ex.getErrorMessage();
            if (message != null) {
                text = message.toString();
            }
        }
        return text.equals("") ? "exception" : text;
    }

    //! Start looking for the car. When an address is supplied, it is an exact
    //! filter and no nearby unnamed device will be tried as a fallback.
    function startScan(localName as String, targetAddress as String?) as Void {
        _targetName = localName;
        _targetAddress = null;
        if (targetAddress != null) {
            var address = normalizeAddress(targetAddress);
            if (address != null) {
                _targetAddress = address;
            }
        }
        _scanDesired = true;
        _rejectedResults = [];
        _rejected = 0;
        _attempted = 0;
        if (_scanning) {
            return;
        }
        enableScan();
    }

    //! Scan without connecting, recording every advertisement seen.
    //!
    //! "Car not found" on its own says nothing about why: the advertisement
    //! may be absent, or present but not matching. This makes the difference
    //! visible.
    function startDiagnosticScan() as Void {
        _diagnostic = true;
        _scanDesired = true;
        _discovered = [];
        enableScan();
    }

    //! Strongest signal first: standing next to the car, it should lead.
    //! Whether any candidate was connected to during this scan. Separates
    //! "never saw anything worth trying" from "tried and none was a Tesla".
    function hasTriedCandidates() as Boolean {
        return _attempted > 0;
    }

    function getDiscovered() as Array {
        var sorted = [];
        var remaining = _discovered.slice(0, null);
        while (remaining.size() > 0) {
            var best = 0;
            for (var i = 1; i < remaining.size(); i++) {
                if (((remaining[i] as Dictionary).get(:rssi) as Number) >
                    ((remaining[best] as Dictionary).get(:rssi) as Number)) {
                    best = i;
                }
            }
            sorted.add(remaining[best]);
            var next = remaining.slice(0, best);
            next.addAll(remaining.slice(best + 1, null));
            remaining = next;
        }
        return sorted;
    }

    private function hex16(value as Number) as String {
        return "0x" + CryptoUtils.hexByte((value >> 8) & 0xFF) +
               CryptoUtils.hexByte(value & 0xFF);
    }

    private function hexBytes(data as ByteArray, limit as Number) as String {
        var out = "";
        var count = data.size() < limit ? data.size() : limit;
        for (var i = 0; i < count; i++) {
            out += CryptoUtils.hexByte(data[i]);
        }
        return out;
    }

    function stopScan() as Void {
        _diagnostic = false;
        _scanDesired = false;
        _scanTimer.stop();
        if (!_scanning) {
            return;
        }
        try {
            Ble.setScanState(Ble.SCAN_STATE_OFF);
        } catch (ex) {
            // Already off, or BLE went away underneath us.
        }
    }

    //! True only once the link is actually up. pairDevice hands back a Device
    //! before the connection completes, so holding a handle proves nothing.
    function isConnected() as Boolean {
        return _connected && _device != null;
    }

    //! Bytes handed to the radio, bytes arriving as notifications, and whole
    //! framed messages reassembled from them.
    function getTraffic() as Array<Number> {
        return [_bytesWritten, _bytesReceived, _messagesReceived];
    }

    //! Queue a message for transmission, adding Tesla's length prefix.
    function send(message as ByteArray) as Void {
        if (_device == null) {
            notify(:onBleError, "Not connected");
            return;
        }

        var framed = [(message.size() >> 8) & 0xFF, message.size() & 0xFF]b;
        framed.addAll(message);
        DebugLog.add("tx " + message.size().toString() + "b " + DebugLog.hex(message, 4));

        for (var offset = 0; offset < framed.size(); offset += CHUNK_SIZE) {
            var end = offset + CHUNK_SIZE;
            if (end > framed.size()) {
                end = framed.size();
            }
            _txChunks.add(framed.slice(offset, end));
        }
        pumpWrites();
    }

    //! Tear everything down, including a connection attempt that never
    //! completed. Every failure path ends here so the next attempt starts
    //! from nothing rather than from whatever the last one left behind.
    function close() as Void {
        stopScan();
        _verifyTimer.stop();
        // Flags first: unpairing produces a disconnect callback, which must
        // read as our own doing rather than as the car dropping the link.
        var device = _device;
        _device = null;
        _connecting = false;
        _connected = false;
        _identifying = false;
        _rejected = 0;
        _attempted = 0;
        _rejectedResults = [];
        if (device != null) {
            DebugLog.add("ble close");
            try {
                Ble.unpairDevice(device);
            } catch (ex) {
                // Nothing useful to do if the device has already gone.
            }
        }
        _rxBuffer = []b;
        _txChunks = [];
        _writeInFlight = false;
    }

    // ---- Ble.BleDelegate callbacks ----

    function onScanStateChange(scanState as Ble.ScanState, status as Ble.Status) as Void {
        _scanning = (scanState == Ble.SCAN_STATE_SCANNING);
        if (status != Ble.STATUS_SUCCESS) {
            DebugLog.add("! scan status " + status.toString());
        }

        // Scanning stopping while it is still wanted is normal, not an error.
        // Restart it, or a slowly advertising car is never seen.
        if (!_scanning && _scanDesired && !_connecting) {
            _scanTimer.stop();
            _scanTimer.start(method(:resumeScan), 1000, false);
        }
    }

    //! Public because Timer needs a bound method reference to it.
    function resumeScan() as Void {
        if (_scanDesired && !_scanning && !_connecting) {
            enableScan();
        }
    }

    //! Stop the radio without giving up the intent to scan, so the keep-alive
    //! knows to resume once a connection attempt resolves.
    private function pauseScan() as Void {
        try {
            Ble.setScanState(Ble.SCAN_STATE_OFF);
        } catch (ex) {
            // Already off.
        }
    }

    private function enableScan() as Void {
        try {
            Ble.setScanState(Ble.SCAN_STATE_SCANNING);
        } catch (ex) {
            notify(:onBleError, "Bluetooth unavailable");
        }
    }

    function onScanResults(scanResults as Ble.Iterator) as Void {
        for (var result = scanResults.next(); result != null; result = scanResults.next()) {
            if (!(result instanceof Ble.ScanResult)) {
                continue;
            }
            if (_diagnostic) {
                record(result);
                continue;
            }
            if (isCandidate(result)) {
                pauseScan();
                _connecting = true;
                _attempted++;
                DebugLog.add("try " + result.getRssi().toString() +
                    (matches(result) ? " match" : " nameless"));
                logAdvertisement(result);
                try {
                    _currentResult = result;
                    _device = Ble.pairDevice(result);
                    if (_device == null) {
                        _connecting = false;
                        DebugLog.add("! pairDevice returned null");
                        rememberCurrentResult();
                        notify(:onBleRetry, null);
                        resumeScan();
                        return;
                    }
                    notify(:onBleConnecting, null);
                } catch (ex) {
                    _connecting = false;
                    DebugLog.add("! pairDevice threw, retry");
                    rememberCurrentResult();
                    notify(:onBleRetry, null);
                    resumeScan();
                }
                return;
            }
        }
    }

    function onConnectedStateChanged(device as Ble.Device, state as Ble.ConnectionState) as Void {
        if (state == Ble.CONNECTION_STATE_CONNECTED) {
            var name = device.getName();
            DebugLog.add("connected" + (name == null ? "" : " " + name));
            _device = device;
            _connecting = false;
            _connected = true;

            // Identify the car after connecting rather than before, since its
            // advertisement carries nothing to match on. The GATT table is not
            // populated the instant the connection reports connected, though,
            // so give discovery time and look again before giving up.
            _verifyAttempts = 0;
            _verifyTimer.stop();
            _verifyTimer.start(method(:verifyService), VERIFY_INTERVAL_MS, false);
        } else {
            // Three things look like a disconnect: the car dropping a live
            // link, a connection attempt that never came up, and our own
            // unpairing of a rejected device. Only the first two need acting
            // on, and differently.
            var wasConnected = _connected;
            var wasConnecting = _connecting;
            _device = null;
            _connecting = false;
            _connected = false;
            _verifyTimer.stop();
            if (wasConnected) {
                DebugLog.add("disconnected");
                notify(:onBleDisconnected, null);
            } else if (wasConnecting) {
                rememberCurrentResult();
                DebugLog.add("connect failed, rescan");
                notify(:onBleRetry, null);
                resumeScan();
            }
        }
    }

    //! Abort a connection attempt that exceeded the manager's overall window
    //! and continue with another scan result. This keeps Pair from getting
    //! stuck on one peripheral that never completes GATT connection.
    function retryConnection() as Void {
        if (!_connecting) {
            return;
        }
        var device = _device;
        _device = null;
        _connecting = false;
        _connected = false;
        _verifyTimer.stop();
        _identifying = false;
        rememberCurrentResult();
        if (device != null) {
            try {
                Ble.unpairDevice(device);
            } catch (ex) {
                // The peripheral may already have disconnected.
            }
        }
        DebugLog.add("connect timeout, retry");
        notify(:onBleRetry, null);
        resumeScan();
    }

    //! Look for Tesla's VCSEC service in the connected device's GATT table.
    //!
    //! Public because Timer needs a bound method reference to it.
    function verifyService() as Void {
        var device = _device;
        if (device == null) {
            return;
        }

        if (device.getService(_service) != null) {
            DebugLog.add("vcsec svc after " + (_verifyAttempts + 1).toString());
            _rejected = 0;
            _bytesWritten = 0;
            _bytesReceived = 0;
            _messagesReceived = 0;
            _rxBuffer = []b;
            _txChunks = [];
            _writeInFlight = false;
            enableNotifications();
            return;
        }

        _verifyAttempts++;
        if (_verifyAttempts < VERIFY_ATTEMPTS) {
            _verifyTimer.start(method(:verifyService), VERIFY_INTERVAL_MS, false);
            return;
        }

        // Discovery has had long enough. This is some other device - or the
        // table is still empty, which the service list below will show.
        DebugLog.add("no vcsec svc, " + describeServices(device));
        _rejected++;
        _connected = false;

        // Ask the device what it is before letting go of it. The answer
        // says whether the scan is picking the wrong devices or the right
        // one is failing discovery.
        if (readGapName(device)) {
            _identifying = true;
            _verifyTimer.start(method(:abandonIdentify), IDENTIFY_TIMEOUT_MS, false);
            return;
        }
        finishRejection();
    }

    private function readGapName(device as Ble.Device) as Boolean {
        if (!_gapRegistered) {
            return false;
        }
        var service = device.getService(_gapService);
        if (service == null) {
            DebugLog.add("no gap svc");
            return false;
        }
        var characteristic = service.getCharacteristic(_gapDeviceName);
        if (characteristic == null) {
            DebugLog.add("no gap name char");
            return false;
        }
        try {
            characteristic.requestRead();
            return true;
        } catch (ex) {
            DebugLog.add("gap read threw");
            return false;
        }
    }

    function onCharacteristicRead(characteristic as Ble.Characteristic, status as Ble.Status, value as ByteArray) as Void {
        if (!_identifying) {
            return;
        }
        if (status == Ble.STATUS_SUCCESS) {
            DebugLog.add("it is: " + asText(value));
        } else {
            DebugLog.add("gap read status " + status.toString());
        }
        finishRejection();
    }

    //! Public because Timer needs a bound method reference to it.
    function abandonIdentify() as Void {
        if (_identifying) {
            DebugLog.add("gap read timed out");
            finishRejection();
        }
    }

    //! Drop a device that is not a car and go back to scanning, remembering
    //! it so the scan does not hand it straight back.
    private function finishRejection() as Void {
        _identifying = false;
        _verifyTimer.stop();
        rememberCurrentResult();
        var device = _device;
        _device = null;
        if (device != null) {
            try {
                Ble.unpairDevice(device);
            } catch (ex) {
                // Nothing useful to do if it has already gone.
            }
        }
        notify(:onBleWrongDevice, _rejected);
        resumeScan();
    }

    //! Remember the current scan result before dropping its connection. The
    //! same peripheral can be reported repeatedly while the scan is running.
    private function rememberCurrentResult() as Void {
        if (_currentResult != null && _rejectedResults.size() < 8) {
            _rejectedResults.add(_currentResult);
        }
        _currentResult = null;
    }

    //! What the GATT table holds, for the log. Distinguishes a device that
    //! is not a Tesla (other services present) from discovery that has not
    //! finished (nothing present at all).
    private function describeServices(device as Ble.Device) as String {
        var out = "";
        var count = 0;
        try {
            var iterator = device.getServices();
            for (var service = iterator.next(); service != null; service = iterator.next()) {
                count++;
                if (count <= 3 && service instanceof Ble.Service) {
                    var text = service.getUuid().toString();
                    out += " " + (text.length() > 8 ? text.substring(0, 8) as String : text);
                }
            }
        } catch (ex) {
            return "svcs threw";
        }
        return count.toString() + " svcs" + out;
    }

    function onDescriptorWrite(descriptor as Ble.Descriptor, status as Ble.Status) as Void {
        // Notifications are live, so the vehicle can now reply. Only at this
        // point is the link actually usable.
        if (status == Ble.STATUS_SUCCESS) {
            DebugLog.add("notify on");
            notify(:onBleConnected, null);
        } else {
            DebugLog.add("! cccd status " + status.toString());
            notify(:onBleError, "Link setup failed");
        }
    }

    function onCharacteristicWrite(characteristic as Ble.Characteristic, status as Ble.Status) as Void {
        _writeInFlight = false;
        if (status != Ble.STATUS_SUCCESS) {
            _txChunks = [];
            DebugLog.add("! write status " + status.toString());
            notify(:onBleError, "Send failed");
            return;
        }
        if (_txChunks.size() == 0) {
            DebugLog.add("tx done");
        }
        pumpWrites();
    }

    function onCharacteristicChanged(characteristic as Ble.Characteristic, value as ByteArray) as Void {
        if (!characteristic.getUuid().equals(_readChar)) {
            return;
        }
        _bytesReceived += value.size();
        _rxBuffer.addAll(value);
        drainMessages();
    }

    // ---- internals ----

    //! Note what an advertisement carries, for the diagnostics screen. Keeps
    //! the strongest signal per name and caps the list, since a busy area
    //! produces far more devices than a watch can show or hold.
    private function record(result as Ble.ScanResult) as Void {
        var adv = parseAdvertisement(result);
        var name = result.getDeviceName();
        if (name == null) {
            name = adv.get(:name) as String?;
        }
        var label = (name == null) ? "(no name)" : name;
        var rssi = result.getRssi();

        var advertisesTesla = adv.get(:tesla) as Boolean;
        var uuids = result.getServiceUuids();
        for (var uuid = uuids.next(); uuid != null; uuid = uuids.next()) {
            if (uuid.equals(_service)) {
                advertisesTesla = true;
            }
        }

        // Connect IQ does not reliably surface the advertised local name, and
        // Tesla does not advertise its service uuid - it only appears in the
        // GATT table once connected. Manufacturer data is what is left to
        // recognise a car by, so show it.
        var manufacturer = "";
        var iterator = result.getManufacturerSpecificDataIterator();
        for (var entry = iterator.next(); entry != null; entry = iterator.next()) {
            if (!(entry instanceof Dictionary)) {
                continue;
            }
            var companyId = entry.get(:companyId);
            var payload = entry.get(:data);
            if (companyId instanceof Lang.Number) {
                manufacturer = hex16(companyId);
            }
            if (payload instanceof ByteArray) {
                manufacturer += " " + hexBytes(payload, 4);
            }
            break;
        }
        // With nothing else to show, show the advertisement itself. Two
        // devices that differ only in their payload get separate rows.
        if (manufacturer.equals("")) {
            manufacturer = adv.get(:hex) as String;
        }

        // Key on name AND manufacturer data, not name alone. Unnamed devices
        // are exactly what this screen exists to find, and keying on the
        // label alone collapsed every one of them into a single "(no name)"
        // row - hiding the car behind whatever unnamed device was loudest.
        for (var i = 0; i < _discovered.size(); i++) {
            var seen = _discovered[i] as Dictionary;
            var sameName = (seen.get(:label) as String).equals(label);
            var sameManufacturer = (seen.get(:manufacturer) as String).equals(manufacturer);
            if (sameName && sameManufacturer) {
                if (rssi > (seen.get(:rssi) as Number)) {
                    seen.put(:rssi, rssi);
                }
                if (advertisesTesla) {
                    seen.put(:tesla, true);
                }
                return;
            }
        }

        if (_discovered.size() >= 12) {
            return;
        }
        _discovered.add({
            :label => label,
            :rssi => rssi,
            :tesla => advertisesTesla,
            :isMatch => matches(result),
            :manufacturer => manufacturer
        });
        // The whole advertisement of each new device goes to the log, where
        // it can be read back and decoded. The screen row only has room for
        // the first few bytes.
        if (_discovered.size() <= 8) {
            DebugLog.add("d" + _discovered.size().toString() + " " + rssi.toString() + " " + label);
            logAdvertisement(result);
        }
        notify(:onBleScanChanged, null);
    }

    //! The raw advertisement bytes, split across log lines short enough to
    //! fit the screen: eleven bytes per line, so a full 31-byte payload
    //! takes three.
    private function logAdvertisement(result as Ble.ScanResult) as Void {
        if (!(result has :getRawData)) {
            DebugLog.add("  adv n/a");
            return;
        }
        var data = null;
        try {
            data = result.getRawData();
        } catch (ex) {
            DebugLog.add("  adv threw");
            return;
        }
        if (!(data instanceof ByteArray)) {
            DebugLog.add("  adv null");
            return;
        }
        if (data.size() == 0) {
            DebugLog.add("  adv empty");
            return;
        }
        for (var offset = 0; offset < data.size(); offset += 11) {
            var end = offset + 11 < data.size() ? offset + 11 : data.size();
            DebugLog.add("  " + hexBytes(data.slice(offset, end), 11));
        }
    }

    //! Worth connecting to and inspecting.
    //!
    //! A definite match is taken as-is. Otherwise this accepts a nameless
    //! advertisement carrying no manufacturer data, which is what a Tesla
    //! looks like through Connect IQ, and which excludes the beacons and
    //! consumer electronics that fill a scan. Signal strength keeps it to
    //! devices that are plausibly the car in front of you.
    private function isCandidate(result as Ble.ScanResult) as Boolean {
        if (matches(result)) {
            return true;
        }
        // An exact address is an explicit debugging choice. Do not connect to
        // an unrelated nameless peripheral when it is configured.
        if (_targetAddress != null) {
            return false;
        }
        if (result.getDeviceName() != null) {
            return false;
        }
        if (result.getRssi() < CANDIDATE_MIN_RSSI) {
            return false;
        }
        if (result.getManufacturerSpecificDataIterator().next() != null) {
            return false;
        }
        return !wasRejected(result);
    }

    private function wasRejected(result as Ble.ScanResult) as Boolean {
        if (!(result has :isSameDevice)) {
            return false;
        }
        for (var i = 0; i < _rejectedResults.size(); i++) {
            if (result.isSameDevice(_rejectedResults[i] as Ble.ScanResult)) {
                return true;
            }
        }
        return false;
    }

    //! Read the advertisement bytes directly. Connect IQ's own parsing did
    //! not surface the car's name or service uuid on hardware, and the
    //! bytes themselves say whether they were ever there to surface.
    //!
    //! Returns {:name, :tesla, :hex}; hex is the first bytes of the payload.
    private function parseAdvertisement(result as Ble.ScanResult) as Dictionary {
        var out = {:name => null, :tesla => false, :hex => ""};
        if (!(result has :getRawData)) {
            out.put(:hex, "raw n/a");
            return out;
        }
        var data = null;
        try {
            data = result.getRawData();
        } catch (ex) {
            out.put(:hex, "raw threw");
            return out;
        }
        if (!(data instanceof ByteArray)) {
            out.put(:hex, "raw null");
            return out;
        }
        out.put(:hex, hexBytes(data, 8));

        var i = 0;
        while (i < data.size()) {
            var length = data[i];
            if (length == 0 || i + 1 + length > data.size()) {
                break;
            }
            var type = data[i + 1];
            var start = i + 2;
            var end = i + 1 + length;
            if (type == AD_INCOMPLETE_128BIT_UUIDS || type == AD_COMPLETE_128BIT_UUIDS) {
                for (var j = start; j + 16 <= end; j += 16) {
                    if (bytesAt(data, j, _teslaUuidLe)) {
                        out.put(:tesla, true);
                    }
                }
            } else if (type == AD_SHORT_NAME || type == AD_COMPLETE_NAME) {
                out.put(:name, asText(data.slice(start, end)));
            }
            i = end;
        }
        return out;
    }

    private function bytesAt(data as ByteArray, offset as Number, expected as ByteArray) as Boolean {
        if (offset + expected.size() > data.size()) {
            return false;
        }
        for (var i = 0; i < expected.size(); i++) {
            if (data[offset + i] != expected[i]) {
                return false;
            }
        }
        return true;
    }

    //! Printable ASCII from bytes; anything else becomes a dot.
    private function asText(data as ByteArray) as String {
        var out = "";
        for (var i = 0; i < data.size() && i < 24; i++) {
            var b = data[i];
            out += (b >= 0x20 && b < 0x7f) ? b.toChar().toString() : ".";
        }
        return out;
    }

    //! Settings editors differ in whether they permit punctuation in an
    //! alphaNumeric value. Accept both the nRF Connect form
    //! "AA:BB:CC:DD:EE:FF" and the punctuation-free "AABBCCDDEEFF" form,
    //! then pass the colon form required by ScanResult.hasAddress().
    private function normalizeAddress(value as String) as String? {
        var compact = "";
        for (var i = 0; i < value.length(); i++) {
            var part = value.substring(i, i + 1) as String;
            if (!part.equals(":")) {
                compact += part;
            }
        }
        if (compact.length() != 12) {
            return null;
        }
        compact = compact.toUpper();
        var formatted = "";
        for (var offset = 0; offset < 12; offset += 2) {
            if (offset > 0) {
                formatted += ":";
            }
            formatted += compact.substring(offset, offset + 2) as String;
        }
        return formatted;
    }

    //! Prefer an exact local-name match, which identifies one specific VIN.
    //! Connect IQ does not always populate the device name in a scan result, so
    //! fall back to any device advertising Tesla's service UUID - the wrong car
    //! would fail the personalised handshake anyway.
    private function matches(result as Ble.ScanResult) as Boolean {
        if (_targetAddress != null) {
            try {
                return result.hasAddress(_targetAddress);
            } catch (ex) {
                return false;
            }
        }
        var adv = parseAdvertisement(result);
        if (adv.get(:tesla) as Boolean) {
            return true;
        }
        var name = result.getDeviceName();
        if (name == null) {
            name = adv.get(:name) as String?;
        }
        if (name != null && _targetName != null) {
            // Tesla's spec gives the name with lower-case hex, but a real car
            // was observed advertising it upper-case. Compare without case.
            return name.toLower().equals(_targetName.toLower());
        }
        var uuids = result.getServiceUuids();
        for (var uuid = uuids.next(); uuid != null; uuid = uuids.next()) {
            if (uuid.equals(_service)) {
                return true;
            }
        }
        return false;
    }

    private function enableNotifications() as Void {
        var characteristic = readCharacteristic();
        if (characteristic == null) {
            DebugLog.add("! no read char");
            notify(:onBleError, "Tesla service missing");
            return;
        }
        var descriptor = characteristic.getDescriptor(Ble.cccdUuid());
        if (descriptor == null) {
            DebugLog.add("! no cccd");
            notify(:onBleError, "Tesla service missing");
            return;
        }
        try {
            // Tesla's reference BLE connector subscribes with indications
            // (the `ind` argument is true). Garmin exposes the same choice via
            // the CCCD bits: 0x0002 enables indications, 0x0001 notifications.
            descriptor.requestWrite([0x02, 0x00]b);
        } catch (ex) {
            DebugLog.add("! cccd write threw");
            notify(:onBleError, "Link setup failed");
        }
    }

    private function readCharacteristic() as Ble.Characteristic? {
        if (_device == null) {
            return null;
        }
        var service = _device.getService(_service);
        if (service == null) {
            return null;
        }
        return service.getCharacteristic(_readChar);
    }

    //! Send the next queued chunk if the radio is idle.
    private function pumpWrites() as Void {
        if (_writeInFlight || _txChunks.size() == 0 || _device == null) {
            return;
        }
        var service = _device.getService(_service);
        if (service == null) {
            return;
        }
        var characteristic = service.getCharacteristic(_writeChar);
        if (characteristic == null) {
            return;
        }

        var chunk = _txChunks[0] as ByteArray;
        _txChunks = _txChunks.slice(1, null);
        _writeInFlight = true;
        try {
            characteristic.requestWrite(chunk, {:writeType => Ble.WRITE_TYPE_WITH_RESPONSE});
            _bytesWritten += chunk.size();
        } catch (ex) {
            _writeInFlight = false;
            _txChunks = [];
            DebugLog.add("! write threw");
            notify(:onBleError, "Send failed");
        }
    }

    //! Pull every complete message out of the receive buffer.
    private function drainMessages() as Void {
        while (_rxBuffer.size() >= 2) {
            var length = (_rxBuffer[0] << 8) | _rxBuffer[1];
            if (length > MAX_MESSAGE_SIZE) {
                // The stream is out of step with the framing; there is no way
                // to resynchronise mid-stream, so start over.
                DebugLog.add("! bad frame " + DebugLog.hex(_rxBuffer, 4));
                _rxBuffer = []b;
                notify(:onBleError, "Bad response");
                return;
            }
            if (_rxBuffer.size() < length + 2) {
                return;
            }
            var message = _rxBuffer.slice(2, length + 2);
            _rxBuffer = _rxBuffer.slice(length + 2, null);
            _messagesReceived++;
            DebugLog.add("rx " + length.toString() + "b " + DebugLog.hex(message, 6));
            notify(:onBleMessage, message);
        }
    }

    private function notify(event as Symbol, argument) as Void {
        if (_listener != null && _listener has :onBleEvent) {
            _listener.onBleEvent(event, argument);
        }
    }
}
