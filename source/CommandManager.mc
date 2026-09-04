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

    //! Connecting, discovering the GATT table and enabling notifications all
    //! happen inside this window. On hardware the car alone took up to twelve
    //! seconds to connect, and discovery is allowed fifteen more after that.
    private const CONNECT_TIMEOUT_MS = 35000;

    //! A signed command that gets no reply in this window has been lost.
    private const COMMAND_TIMEOUT_MS = 8000;

    //! Pairing is not a request-response exchange: the car waits for a key
    //! card to be tapped on the console and then for a confirmation on its
    //! screen. Eight seconds cannot tell a silent car from an unhurried one.
    private const PAIRING_TIMEOUT_MS = 45000;

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
                DebugLog.add("vin ok, name " + CryptoUtils.bleLocalName(vin));
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
        DebugLog.add("cmd " + DebugLog.hex(payload, 4));
        dispatch();
    }

    //! Ask the car to whitelist this watch. Sent with no session - the car
    //! authorises it by a key card tap, not by a shared secret this watch does
    //! not have yet.
    function sendPairingRequest() as Void {
        if (!hasVin()) {
            setState(STATE_NO_VIN, "");
            return;
        }
        _pendingPayload = Vcsec.addKeyRequest(CryptoUtils.publicKey(), Vcsec.ROLE_DRIVER);
        _pendingIsPairing = true;
        DebugLog.add("pair key " + DebugLog.hex(CryptoUtils.publicKey().slice(1, 4), 3));
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

    //! [bytes written, bytes received, messages reassembled] on the current
    //! connection.
    function getTraffic() as Array<Number> {
        return _transport.getTraffic();
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
        if (event == :onBleWrongDevice) {
            // Connected to something that turned out not to be a car, and the
            // scan has resumed. Show the count so a long search looks like
            // progress rather than a hang, and give the scan its window back.
            setState(STATE_SCANNING, "Checking " + argument.toString());
            restartTimer(SCAN_TIMEOUT_MS);
        } else if (event == :onBleScanChanged) {
            // Nothing to decide, just show what arrived.
            if (_onChange != null) {
                _onChange.invoke();
            }
        } else if (event == :onBleConnecting) {
            setState(STATE_CONNECTING, "");
            restartTimer(CONNECT_TIMEOUT_MS);
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
            DebugLog.add("busy, dropped");
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
        // A link dropping mid-exchange is a failure worth naming. One dropping
        // while idle is the car going back to sleep, which is normal.
        if (_state == STATE_HANDSHAKE || _state == STATE_SENDING || _state == STATE_CONNECTING) {
            fail("Disconnected");
        } else if (_state != STATE_ERROR) {
            setState(STATE_IDLE, "");
        }
    }

    private function beginHandshake() as Void {
        _lastUuid = CryptoUtils.randomBytes(16);
        DebugLog.add("tx session req");
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
            // Bare ToVCSECMessage, the way Tesla's own client sends it. Not a
            // RoutableMessage: the car ignores the request in that framing.
            message = Vcsec.presentKeyEnvelope(_pendingPayload);
            DebugLog.add("tx pair req");
        } else {
            message = _session.signCommand(_pendingPayload, _routingAddress, _lastUuid);
            DebugLog.add("tx signed cmd");
        }
        setState(STATE_SENDING, "");
        _transport.send(message);
        restartTimer(_pendingIsPairing ? PAIRING_TIMEOUT_MS : COMMAND_TIMEOUT_MS);
    }

    private function onMessage(raw as ByteArray) as Void {
        var message = Protobuf.decode(raw);

        // Replies to a pairing request arrive as bare FromVCSECMessages, not
        // RoutableMessages. The two do not share field numbers - VCSEC reserves
        // 6 to 10, which is where the envelope keeps its addressing - so the
        // fields present say which this is. The timer is left running here:
        // only a reply that settles the exchange stops it.
        if (isRoutable(message)) {
            handleRoutable(message);
        } else {
            DebugLog.add("car: bare vcsec");
            handleVcsecReply(raw);
        }
    }

    private function isRoutable(message as Dictionary) as Boolean {
        return message.hasKey(UniversalMessage.FIELD_TO_DESTINATION) ||
               message.hasKey(UniversalMessage.FIELD_FROM_DESTINATION) ||
               message.hasKey(UniversalMessage.FIELD_PAYLOAD) ||
               message.hasKey(UniversalMessage.FIELD_STATUS) ||
               message.hasKey(UniversalMessage.FIELD_SIGNATURE_DATA) ||
               message.hasKey(UniversalMessage.FIELD_SESSION_INFO);
    }

    private function handleRoutable(message as Dictionary) as Void {
        var fault = UniversalMessage.faultOf(message);
        if (fault != 0) {
            DebugLog.add("car: fault " + fault.toString());
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
            return;
        }
        DebugLog.add("car: empty envelope");
    }

    private function handleSessionInfo(sessionInfo as ByteArray, message as Dictionary) as Void {
        _timer.stop();
        var signature = Protobuf.submessage(message, UniversalMessage.FIELD_SIGNATURE_DATA);
        var tagField = Protobuf.submessage(signature, UniversalMessage.FIELD_SESSION_INFO_TAG);
        var tag = tagField.get(1);

        if (!_session.absorbSessionInfo(sessionInfo, _lastUuid, tag as ByteArray?)) {
            // An unauthenticated handshake response is either a corrupted
            // exchange or an active attack. Either way it cannot be trusted.
            DebugLog.add("car: session tag bad");
            fail("Handshake failed");
            return;
        }

        DebugLog.add("car: session ok");
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
            DebugLog.add("car: lock " + lockState.toString());
            if (_onChange != null) {
                _onChange.invoke();
            }
        }

        var commandStatus = Vcsec.commandStatusOf(payload);
        if (commandStatus == null) {
            if (lockState == null) {
                DebugLog.add("car: other " + DebugLog.hex(payload, 6));
            }
            return;
        }
        DebugLog.add("car: status " + commandStatus.toString());

        if (commandStatus == Vcsec.OPERATIONSTATUS_WAIT) {
            // During pairing this is the car saying it is ready for the key
            // card, and the window has to allow for a person walking to the
            // console. Outside pairing it just means VCSEC is busy.
            if (_pendingIsPairing) {
                setState(STATE_SENDING, "Tap key card now");
                restartTimer(PAIRING_TIMEOUT_MS);
            } else {
                restartTimer(COMMAND_TIMEOUT_MS);
            }
            return;
        }

        _timer.stop();
        var wasPairing = _pendingIsPairing;
        _pendingPayload = null;
        _pendingIsPairing = false;

        if (commandStatus == Vcsec.OPERATIONSTATUS_ERROR) {
            if (wasPairing) {
                var reason = Vcsec.whitelistInformationOf(payload);
                DebugLog.add("car: whitelist " + reason.toString());
                fail(reason == 0 ? "Pairing failed" : Vcsec.whitelistInformationText(reason));
            } else {
                fail("Rejected");
            }
            return;
        }

        if (wasPairing) {
            // Accepted. The proof is a session: hand-shake now, so the main
            // screen going to Connected confirms the key really is on the
            // whitelist rather than just acknowledged.
            setState(STATE_HANDSHAKE, "Paired");
            beginHandshake();
            return;
        }
        setState(STATE_READY, "Done");
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
        // Name the phase that timed out. "Car not found" covers three very
        // different failures - never saw a candidate, could not connect to
        // one, or connected and found no Tesla service - and telling them
        // apart from the watch face saves a debugging round trip.
        if (_state == STATE_SCANNING) {
            fail(_transport.hasTriedCandidates() ? "No Tesla found" : "No car seen");
        } else if (_state == STATE_CONNECTING) {
            fail("Connect failed");
        } else if (_state == STATE_HANDSHAKE) {
            fail("No handshake");
        } else {
            fail("No response");
        }
    }

    private function fail(reason as String) as Void {
        _timer.stop();
        _pendingPayload = null;
        _pendingIsPairing = false;
        DebugLog.add("! " + reason);
        // Drop the link, whatever state it is in. A stalled connection left
        // in place made every later attempt believe it was already connected.
        _transport.close();
        setState(STATE_ERROR, reason);
    }

    private function restartTimer(durationMs as Number) as Void {
        _timer.stop();
        _timer.start(method(:onTimeout), durationMs, false);
    }

    private function setState(state as State, text as String) as Void {
        if (state != _state || !text.equals(_statusText)) {
            DebugLog.add(stateName(state) + (text.equals("") ? "" : " " + text));
        }
        _state = state;
        _statusText = text;
        if (_onChange != null) {
            _onChange.invoke();
        }
    }

    private function stateName(state as State) as String {
        if (state == STATE_NO_VIN) {
            return "no vin";
        } else if (state == STATE_IDLE) {
            return "idle";
        } else if (state == STATE_SCANNING) {
            return "scan";
        } else if (state == STATE_CONNECTING) {
            return "connect";
        } else if (state == STATE_HANDSHAKE) {
            return "handshake";
        } else if (state == STATE_READY) {
            return "ready";
        } else if (state == STATE_SENDING) {
            return "sending";
        }
        return "error";
    }
}
