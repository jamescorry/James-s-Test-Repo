import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Actions in selection order.
enum Action {
    ACTION_UNLOCK,
    ACTION_LOCK,
    ACTION_TRUNK,
    ACTION_FRUNK,
    ACTION_DIAGNOSE,
    ACTION_LOG,
    ACTION_COUNT
}

//! The single screen: the currently selected action, and what the link is
//! doing. Drawn rather than laid out so the same code works on round, semi
//! round and rectangular displays.
class MainView extends WatchUi.View {
    private var _manager as CommandManager;
    private var _selected as Number = ACTION_UNLOCK;

    function initialize(manager as CommandManager) {
        View.initialize();
        _manager = manager;
    }

    function getSelected() as Number {
        return _selected;
    }

    function selectNext() as Void {
        _selected = (_selected + 1) % ACTION_COUNT;
        WatchUi.requestUpdate();
    }

    function selectPrevious() as Void {
        _selected = (_selected + ACTION_COUNT - 1) % ACTION_COUNT;
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();

        // Drawn near the top, where a round screen has narrowed, so this gets
        // less width than the action label below it.
        dc.setColor(statusColour(), Graphics.COLOR_TRANSPARENT);
        TextLayout.drawCentered(
            dc,
            statusLine(),
            Graphics.FONT_TINY,
            width / 2,
            (height * 0.22).toNumber(),
            (width * 0.60).toNumber()
        );

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height / 2,
            Graphics.FONT_LARGE,
            actionLabel(_selected),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        drawSelectionDots(dc, width, height);

        // Always visible, so a fresh sideload is recognisable at a glance.
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            width / 2,
            height * 0.89,
            Graphics.FONT_XTINY,
            Version.label(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    //! One dot per action showing which action is selected - cheaper to read at a
    //! glance than a scrolling list, and it fits a round screen.
    private function drawSelectionDots(dc as Dc, width as Number, height as Number) as Void {
        var spacing = 16;
        var radius = 3;
        var startX = width / 2 - (spacing * (ACTION_COUNT - 1)) / 2;
        var y = height * 0.78;

        for (var i = 0; i < ACTION_COUNT; i++) {
            if (i == _selected) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(startX + i * spacing, y, radius);
            } else {
                dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(startX + i * spacing, y, radius - 1);
            }
        }
    }

    private function actionLabel(action as Number) as String {
        if (action == ACTION_LOCK) {
            return WatchUi.loadResource(Rez.Strings.CmdLock) as String;
        } else if (action == ACTION_TRUNK) {
            return WatchUi.loadResource(Rez.Strings.CmdTrunk) as String;
        } else if (action == ACTION_FRUNK) {
            return WatchUi.loadResource(Rez.Strings.CmdFrunk) as String;
        } else if (action == ACTION_DIAGNOSE) {
            return WatchUi.loadResource(Rez.Strings.CmdDiagnose) as String;
        } else if (action == ACTION_LOG) {
            return WatchUi.loadResource(Rez.Strings.CmdLog) as String;
        }
        return WatchUi.loadResource(Rez.Strings.CmdUnlock) as String;
    }

    //! A one-line summary of the link. An explicit message from the manager
    //! wins over the generic state text.
    private function statusLine() as String {
        var text = _manager.getStatusText();
        if (!text.equals("")) {
            return text;
        }

        var state = _manager.getState();
        if (state == STATE_NO_VIN) {
            return WatchUi.loadResource(Rez.Strings.StateNoVin) as String;
        } else if (state == STATE_SCANNING) {
            return WatchUi.loadResource(Rez.Strings.StateScanning) as String;
        } else if (state == STATE_CONNECTING) {
            return WatchUi.loadResource(Rez.Strings.StateConnecting) as String;
        } else if (state == STATE_HANDSHAKE) {
            return WatchUi.loadResource(Rez.Strings.StateHandshake) as String;
        } else if (state == STATE_READY) {
            var lockState = _manager.getLockState();
            if (lockState != null) {
                return WatchUi.loadResource(
                    lockState == Vcsec.VEHICLELOCKSTATE_UNLOCKED
                        ? Rez.Strings.StateUnlocked
                        : Rez.Strings.StateLocked
                ) as String;
            }
            return WatchUi.loadResource(Rez.Strings.StateConnected) as String;
        } else if (state == STATE_SENDING) {
            return WatchUi.loadResource(Rez.Strings.StateSending) as String;
        }
        return WatchUi.loadResource(Rez.Strings.StateIdle) as String;
    }

    private function statusColour() as Number {
        var state = _manager.getState();
        if (state == STATE_ERROR || state == STATE_NO_VIN) {
            return Graphics.COLOR_RED;
        } else if (state == STATE_READY) {
            return Graphics.COLOR_GREEN;
        }
        return Graphics.COLOR_LT_GRAY;
    }
}
