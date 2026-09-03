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

    //! Connect IQ's per-write payload limit.
    private const CHUNK_SIZE = 20;

    //! Tesla's VCSEC will not accept a message larger than this, so a claimed
    //! length beyond it means the stream has desynchronised.
    private const MAX_MESSAGE_SIZE = 1024;

    private var _service as Ble.Uuid;
    private var _writeChar as Ble.Uuid;
    private var _readChar as Ble.Uuid;

    private var _listener;
    private var _targetName as String?;
    private var _device as Ble.Device?;
    private var _scanning as Boolean = false;

    // Connect IQ stops scanning on its own, so wanting to scan and actually
    // scanning are different things. A car advertising slowly while parked
    // falls outside a short window entirely.
    private var _scanDesired as Boolean = false;
    private var _scanTimer as Timer.Timer;

    // Diagnostics: collect what the scan sees instead of connecting to it.
    private var _diagnostic as Boolean = false;
    private var _discovered as Array = [];

    private var _rxBuffer as ByteArray = []b;
    private var _txChunks as Array = [];
    private var _writeInFlight as Boolean = false;

    function initialize(listener) {
        BleDelegate.initialize();
        _listener = listener;
        _scanTimer = new Timer.Timer();
        _service = Ble.stringToUuid(SERVICE_UUID);
        _writeChar = Ble.stringToUuid(WRITE_CHAR_UUID);
        _readChar = Ble.stringToUuid(READ_CHAR_UUID);
    }

    //! Register the Tesla GATT profile. Must be called once, before scanning,
    //! and Connect IQ allows only a small number of registered profiles.
    function open() as Void {
        Ble.setDelegate(self);
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
    }

    //! Start looking for the car whose VIN hashes to `localName`.
    function startScan(localName as String) as Void {
        _targetName = localName;
        _scanDesired = true;
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

    function isConnected() as Boolean {
        return _device != null;
    }

    //! Queue a message for transmission, adding Tesla's length prefix.
    function send(message as ByteArray) as Void {
        if (_device == null) {
            notify(:onBleError, "Not connected");
            return;
        }

        var framed = [(message.size() >> 8) & 0xFF, message.size() & 0xFF]b;
        framed.addAll(message);

        for (var offset = 0; offset < framed.size(); offset += CHUNK_SIZE) {
            var end = offset + CHUNK_SIZE;
            if (end > framed.size()) {
                end = framed.size();
            }
            _txChunks.add(framed.slice(offset, end));
        }
        pumpWrites();
    }

    function close() as Void {
        stopScan();
        if (_device != null) {
            try {
                Ble.unpairDevice(_device);
            } catch (ex) {
                // Nothing useful to do if the device has already gone.
            }
            _device = null;
        }
        _rxBuffer = []b;
        _txChunks = [];
        _writeInFlight = false;
    }

    // ---- Ble.BleDelegate callbacks ----

    function onScanStateChange(scanState as Ble.ScanState, status as Ble.Status) as Void {
        _scanning = (scanState == Ble.SCAN_STATE_SCANNING);

        // Scanning stopping while it is still wanted is normal, not an error.
        // Restart it, or a slowly advertising car is never seen.
        if (!_scanning && _scanDesired) {
            _scanTimer.stop();
            _scanTimer.start(method(:resumeScan), 1000, false);
        }
    }

    //! Public because Timer needs a bound method reference to it.
    function resumeScan() as Void {
        if (_scanDesired && !_scanning) {
            enableScan();
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
            if (matches(result)) {
                stopScan();
                try {
                    _device = Ble.pairDevice(result);
                    notify(:onBleConnecting, null);
                } catch (ex) {
                    notify(:onBleError, "Could not connect");
                }
                return;
            }
        }
    }

    function onConnectedStateChanged(device as Ble.Device, state as Ble.ConnectionState) as Void {
        if (state == Ble.CONNECTION_STATE_CONNECTED) {
            _device = device;
            _rxBuffer = []b;
            _txChunks = [];
            _writeInFlight = false;
            enableNotifications();
        } else {
            _device = null;
            notify(:onBleDisconnected, null);
        }
    }

    function onDescriptorWrite(descriptor as Ble.Descriptor, status as Ble.Status) as Void {
        // Notifications are live, so the vehicle can now reply. Only at this
        // point is the link actually usable.
        if (status == Ble.STATUS_SUCCESS) {
            notify(:onBleConnected, null);
        } else {
            notify(:onBleError, "Link setup failed");
        }
    }

    function onCharacteristicWrite(characteristic as Ble.Characteristic, status as Ble.Status) as Void {
        _writeInFlight = false;
        if (status != Ble.STATUS_SUCCESS) {
            _txChunks = [];
            notify(:onBleError, "Send failed");
            return;
        }
        pumpWrites();
    }

    function onCharacteristicChanged(characteristic as Ble.Characteristic, value as ByteArray) as Void {
        if (!characteristic.getUuid().equals(_readChar)) {
            return;
        }
        _rxBuffer.addAll(value);
        drainMessages();
    }

    // ---- internals ----

    //! Note what an advertisement carries, for the diagnostics screen. Keeps
    //! the strongest signal per name and caps the list, since a busy area
    //! produces far more devices than a watch can show or hold.
    private function record(result as Ble.ScanResult) as Void {
        var name = result.getDeviceName();
        var label = (name == null) ? "(no name)" : name;
        var rssi = result.getRssi();

        var advertisesTesla = false;
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
            :matches => matches(result),
            :manufacturer => manufacturer
        });
        notify(:onBleScanChanged, null);
    }

    //! Prefer an exact local-name match, which identifies one specific VIN.
    //! Connect IQ does not always populate the device name in a scan result, so
    //! fall back to any device advertising Tesla's service UUID - the wrong car
    //! would fail the personalised handshake anyway.
    private function matches(result as Ble.ScanResult) as Boolean {
        var name = result.getDeviceName();
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
            notify(:onBleError, "Tesla service missing");
            return;
        }
        var descriptor = characteristic.getDescriptor(Ble.cccdUuid());
        if (descriptor == null) {
            notify(:onBleError, "Tesla service missing");
            return;
        }
        try {
            descriptor.requestWrite([0x01, 0x00]b);
        } catch (ex) {
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
        } catch (ex) {
            _writeInFlight = false;
            _txChunks = [];
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
                _rxBuffer = []b;
                notify(:onBleError, "Bad response");
                return;
            }
            if (_rxBuffer.size() < length + 2) {
                return;
            }
            var message = _rxBuffer.slice(2, length + 2);
            _rxBuffer = _rxBuffer.slice(length + 2, null);
            notify(:onBleMessage, message);
        }
    }

    private function notify(event as Symbol, argument) as Void {
        if (_listener != null && _listener has :onBleEvent) {
            _listener.onBleEvent(event, argument);
        }
    }
}
