import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! A short in-memory event log, readable on the watch.
//!
//! There is no debugger and no console on a watch in a car park. Every BLE
//! callback, state change and message that matters is recorded here with a
//! timestamp, so a failed attempt can be read back line by line instead of
//! being summarised as "no response".
module DebugLog {
    const CAPACITY = 80;

    var _lines as Array<String> = [];
    var _start as Number = -1;

    //! Append one line. Older lines fall off the top.
    function add(text as String) as Void {
        var now = System.getTimer();
        if (_start < 0) {
            _start = now;
        }
        var tenths = (now - _start) / 100;
        var stamp = (tenths / 10).toString() + "." + (tenths % 10).toString();

        _lines.add(stamp + " " + text);
        if (_lines.size() > CAPACITY) {
            _lines = _lines.slice(_lines.size() - CAPACITY, null);
        }
        WatchUi.requestUpdate();
    }

    //! Oldest first.
    function lines() as Array<String> {
        return _lines;
    }

    function clear() as Void {
        _lines = [];
        WatchUi.requestUpdate();
    }

    //! The first `limit` bytes as hex, which is enough to recognise a
    //! message's shape without filling the screen.
    function hex(data as ByteArray, limit as Number) as String {
        var out = "";
        var count = data.size() < limit ? data.size() : limit;
        for (var i = 0; i < count; i++) {
            out += CryptoUtils.hexByte(data[i]);
        }
        if (data.size() > limit) {
            out += "..";
        }
        return out;
    }
}
