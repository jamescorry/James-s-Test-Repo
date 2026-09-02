import Toybox.Lang;
import Toybox.System;
import Toybox.BluetoothLowEnergy as Ble;

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

    private var _rxBuffer as ByteArray = []b;
    private var _txChunks as Array = [];
    private var _writeInFlight as Boolean = false;

    function initialize(listener) {
        BleDelegate.initialize();
        _listener = listener;
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
        if (_scanning) {
            return;
        }
        try {
            Ble.setScanState(Ble.SCAN_STATE_SCANNING);
        } catch (ex) {
            notify(:onBleError, "Bluetooth unavailable");
        }
    }

    function stopScan() as Void {
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
    }

    function onScanResults(scanResults as Ble.Iterator) as Void {
        for (var result = scanResults.next(); result != null; result = scanResults.next()) {
            if (!(result instanceof Ble.ScanResult)) {
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

    //! Prefer an exact local-name match, which identifies one specific VIN.
    //! Connect IQ does not always populate the device name in a scan result, so
    //! fall back to any device advertising Tesla's service UUID - the wrong car
    //! would fail the personalised handshake anyway.
    private function matches(result as Ble.ScanResult) as Boolean {
        var name = result.getDeviceName();
        if (name != null && _targetName != null) {
            return name.equals(_targetName);
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
