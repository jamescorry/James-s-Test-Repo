import Toybox.Lang;
import Toybox.Application;
import Toybox.Application.Properties;
import Toybox.Timer;

//! Link states, shared with the views.
enum State {
    STATE_NO_VIN,
    STATE_IDLE,
    STATE_SCANNING,
    STATE_CONNECTING,
    STATE_HANDSHAKE,
    STATE_READY,
    STATE_SENDING,
    STATE_ERROR
}

//! Drives one command from a button press to a vehicle response.
//!
//! The flow is always: scan for the car, connect, hand-shake with VCSEC, then
//! send. A command requested before the link is up is held and sent as soon as
//! the session is established.
class CommandManager {
    //! Give up on a scan that finds nothing. Connect IQ stops and restarts
    //! scanning underneath us, and a parked car advertises slowly, so this has
    //! to span several scan windows rather than one.
    private const SCAN_TIMEOUT_MS = 45000;

    //! A signed command that gets no reply in this window has been lost.
    private const COMMAND_TIMEOUT_MS = 8000;

    private var _transport as BleTransport;
    private var _session as Session?;
    private var _vin as String?;
    private var _routingAddress as ByteArray;
    private var _lastUuid as ByteArray;

    private var _state as State = STATE_IDLE;
    private var _statusText as String = "";
    private var _lockState as Number? = null;

    private var _pendingPayload as ByteArray?;
    private var _pendingIsPairing as Boolean = false;
    private var _retriedHandshake as Boolean = false;

    private var _timer as Timer.Timer;
    private var _onChange;

    function initialize(onChange) {
        _onChange = onChange;
        _transport = new BleTransport(self);
        _timer = new Timer.Timer();
        // One routing address per app run identifies this client to the car.
        _routingAddress = CryptoUtils.randomBytes(16);
        _lastUuid = CryptoUtils.randomBytes(16);
        reloadVin();
    }

    function start() as Void {
        _transport.open();
    }

    function stop() as Void {
        _timer.stop();
        _transport.close();
        setState(hasVin() ? STATE_IDLE : STATE_NO_VIN, "");
    }

    function getState() as State {
        return _state;
    }

    function getStatusText() as String {
        return _statusText;
    }

    function getLockState() as Number? {
        return _lockState;
    }

    function hasVin() as Boolean {
        return _vin != null && _vin.length() == 17;
    }

    //! Re-read the VIN from app settings. Called at start-up and whenever
    //! settings change on the phone.
    function reloadVin() as Void {
        var vin = null;
        try {
            vin = Properties.getValue("Vin");
        } catch (ex) {
            vin = null;
        }
        if (vin instanceof String && vin.length() == 17) {
            vin = vin.toUpper();
            if (!vin.equals(_vin)) {
                _vin = vin;
                _session = new Session(_vin, UniversalMessage.DOMAIN_VEHICLE_SECURITY);
            }
            if (_state == STATE_NO_VIN) {
                setState(STATE_IDLE, "");
            }
        } else {
            _vin = null;
            _session = null;
            setState(STATE_NO_VIN, "");
        }
    }

    //! Lock, unlock, trunk, frunk. Connects first if necessary.
    function sendCommand(payload as ByteArray) as Void {
        if (!hasVin()) {
            setState(STATE_NO_VIN, "");
            return;
        }
        _pendingPayload = payload;
        _pendingIsPairing = false;
        dispatch();
    }

    //! Ask the car to whitelist this watch. Sent unauthenticated - the car
    //! asks for a key card tap to authorise it.
    function sendPairingRequest() as Void {
        if (!hasVin()) {
            setState(STATE_NO_VIN, "");
            return;
        }
        _pendingPayload = Vcsec.addKeyRequest(CryptoUtils.publicKey(), Vcsec.ROLE_DRIVER);
        _pendingIsPairing = true;
        dispatch();
    }

    //! Scan without connecting, for the diagnostics screen.
    function startDiagnostics() as Void {
        _timer.stop();
        _pendingPayload = null;
        _pendingIsPairing = false;
        _transport.close();
        _transport.startDiagnosticScan();
        setState(STATE_SCANNING, "");
    }

    function stopDiagnostics() as Void {
        _transport.stopScan();
        setState(hasVin() ? STATE_IDLE : STATE_NO_VIN, "");
    }

    function getDiscovered() as Array {
        return _transport.getDiscovered();
    }

    //! The VIN this app is looking for, and the advertisement name it implies.
    function getExpectedName() as String {
        if (!hasVin()) {
            return "";
        }
        return CryptoUtils.bleLocalName(_vin);
    }

    // ---- BLE events ----

    function onBleEvent(event as Symbol, argument) as Void {
        if (event == :onBleScanChanged) {
            // Nothing to decide, just show what arrived.
            if (_onChange != null) {
                _onChange.invoke();
            }
        } else if (event == :onBleConnecting) {
            setState(STATE_CONNECTING, "");
        } else if (event == :onBleConnected) {
            onConnected();
        } else if (event == :onBleDisconnected) {
            onDisconnected();
        } else if (event == :onBleMessage) {
            onMessage(argument as ByteArray);
        } else if (event == :onBleError) {
            fail(argument as String);
        }
    }

    // ---- internals ----

    private function dispatch() as Void {
        // VCSEC is memory constrained and often omits request_uuid from its
        // replies, so there is no way to tell whose response is whose. One
        // command at a time; a second button press while one is in flight is
        // dropped rather than queued.
        if (_state == STATE_SENDING) {
            _pendingPayload = null;
            _pendingIsPairing = false;
            return;
        }

        // Reuse a live link. Reaching the scan below while still connected
        // would start a BLE scan on top of an open connection - which is what
        // happened after a rejected command left the state at ERROR.
        if (_transport.isConnected()) {
            if (_pendingIsPairing || (_session != null && _session.isEstablished())) {
                transmitPending();
            } else {
                setState(STATE_HANDSHAKE, "");
                beginHandshake();
            }
            return;
        }

        if (_state == STATE_SCANNING || _state == STATE_CONNECTING || _state == STATE_HANDSHAKE) {
            // Already on the way; the pending command goes out when ready.
            return;
        }

        setState(STATE_SCANNING, "");
        _transport.startScan(CryptoUtils.bleLocalName(_vin));
        restartTimer(SCAN_TIMEOUT_MS);
    }

    private function onConnected() as Void {
        // A pairing request needs no session: it is authorised by the key card,
        // not by a shared secret this watch does not have yet.
        if (_pendingIsPairing) {
            setState(STATE_SENDING, "");
            transmitPending();
            return;
        }
        setState(STATE_HANDSHAKE, "");
        beginHandshake();
    }

    private function onDisconnected() as Void {
        _timer.stop();
        if (_session != null) {
            _session.invalidate();
        }
        if (_state != STATE_ERROR) {
            setState(STATE_IDLE, "");
        }
    }

    private function beginHandshake() as Void {
        _lastUuid = CryptoUtils.randomBytes(16);
        _transport.send(UniversalMessage.sessionInfoRequest(
            UniversalMessage.DOMAIN_VEHICLE_SECURITY,
            _routingAddress,
            CryptoUtils.publicKey(),
            _lastUuid
        ));
        restartTimer(COMMAND_TIMEOUT_MS);
    }

    private function transmitPending() as Void {
        if (_pendingPayload == null) {
            return;
        }
        _lastUuid = CryptoUtils.randomBytes(16);
        var message;
        if (_pendingIsPairing) {
            message = UniversalMessage.unsignedCommand(
                UniversalMessage.DOMAIN_VEHICLE_SECURITY,
                _routingAddress,
                _pendingPayload,
                _lastUuid
            );
        } else {
            message = _session.signCommand(_pendingPayload, _routingAddress, _lastUuid);
        }
        setState(STATE_SENDING, "");
        _transport.send(message);
        restartTimer(COMMAND_TIMEOUT_MS);
    }

    private function onMessage(raw as ByteArray) as Void {
        _timer.stop();
        var message = Protobuf.decode(raw);

        var fault = UniversalMessage.faultOf(message);
        if (fault != 0) {
            handleFault(fault);
            return;
        }

        var sessionInfo = message.get(UniversalMessage.FIELD_SESSION_INFO);
        if (sessionInfo instanceof ByteArray) {
            handleSessionInfo(sessionInfo, message);
            return;
        }

        var payload = message.get(UniversalMessage.FIELD_PAYLOAD);
        if (payload instanceof ByteArray) {
            handleVcsecReply(payload);
        }
    }

    private function handleSessionInfo(sessionInfo as ByteArray, message as Dictionary) as Void {
        var signature = Protobuf.submessage(message, UniversalMessage.FIELD_SIGNATURE_DATA);
        var tagField = Protobuf.submessage(signature, UniversalMessage.FIELD_SESSION_INFO_TAG);
        var tag = tagField.get(1);

        if (!_session.absorbSessionInfo(sessionInfo, _lastUuid, tag as ByteArray?)) {
            // An unauthenticated handshake response is either a corrupted
            // exchange or an active attack. Either way it cannot be trusted.
            fail("Handshake failed");
            return;
        }

        _retriedHandshake = false;
        setState(STATE_READY, "");
        if (_pendingPayload != null) {
            transmitPending();
        }
    }

    private function handleVcsecReply(payload as ByteArray) as Void {
        // VCSEC sends up to three replies to one request. A status update is
        // worth showing; anything else here is progress noise.
        var lockState = Vcsec.lockStateOf(payload);
        if (lockState != null) {
            _lockState = lockState;
        }

        var commandStatus = Vcsec.commandStatusOf(payload);
        if (commandStatus == null) {
            return;
        }

        if (commandStatus == Vcsec.OPERATIONSTATUS_WAIT) {
            // VCSEC is busy with another request, or waiting on the key card
            // tap during pairing. Either way the command is still in flight.
            restartTimer(COMMAND_TIMEOUT_MS);
            return;
        }

        var wasPairing = _pendingIsPairing;
        _pendingPayload = null;
        _pendingIsPairing = false;

        if (commandStatus == Vcsec.OPERATIONSTATUS_ERROR) {
            fail(wasPairing ? "Pairing failed" : "Rejected");
            return;
        }

        setState(STATE_READY, wasPairing ? "Paired" : "Done");
    }

    private function handleFault(fault as Number) as Void {
        if (UniversalMessage.faultNeedsNewSession(fault) && !_retriedHandshake) {
            // The vehicle rebooted, or the cached counter and clock drifted.
            // One fresh handshake costs no more than the first one did.
            _retriedHandshake = true;
            _session.invalidate();
            setState(STATE_HANDSHAKE, "");
            beginHandshake();
            return;
        }
        _pendingPayload = null;
        _pendingIsPairing = false;
        fail(UniversalMessage.faultText(fault));
    }

    //! Public because Timer needs a bound method reference to it.
    function onTimeout() as Void {
        if (_state == STATE_SCANNING) {
            _transport.stopScan();
            fail("Car not found");
        } else {
            fail("No response");
        }
    }

    private function fail(reason as String) as Void {
        _timer.stop();
        _pendingPayload = null;
        _pendingIsPairing = false;
        setState(STATE_ERROR, reason);
    }

    private function restartTimer(durationMs as Number) as Void {
        _timer.stop();
        _timer.start(method(:onTimeout), durationMs, false);
    }

    private function setState(state as State, text as String) as Void {
        _state = state;
        _statusText = text;
        if (_onChange != null) {
            _onChange.invoke();
        }
    }
}
