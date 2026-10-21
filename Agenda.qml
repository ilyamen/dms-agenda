import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Calendar and tasks from DankCalendar (dcal) on the desktop.
// Left: events by day with a calendar filter. Right: task lists in the style of Google Tasks.
// All data and changes go through `dcal ipc ...`; dcal syncs with Google itself.
DesktopPluginComponent {
    id: root

    minWidth: 420
    minHeight: 240

    property int daysAhead: pluginData.daysAhead ?? 14
    property int refreshMinutes: pluginData.refreshMinutes ?? 5
    property real backgroundOpacity: (pluginData.backgroundOpacity ?? 80) / 100

    property var calendars: []        // every calendar and task list in dcal
    property var events: []
    property var tasks: []
    property var hiddenCalendars: pluginData.hiddenCalendars ?? []
    property var expandedDone: ({})   // calendarId -> whether the completed block is expanded
    property string errorText: ""

    // While the task editor is open the widget takes keyboard input
    property string addingToList: ""
    property bool acceptsKeyboardFocus: addingToList !== ""

    readonly property color bgColor: Theme.withAlpha(Theme.surface, backgroundOpacity)
    readonly property color tileBg: Theme.withAlpha(Theme.surfaceContainerHigh, backgroundOpacity)

    // Google calendars have empty supportedComponents and hold events; task lists are marked holdsTasks
    readonly property var eventCalendars: calendars.filter(c => !c.supportedComponents || c.supportedComponents.indexOf("VEVENT") >= 0)
    readonly property var taskLists: calendars.filter(c => c.holdsTasks && (c.supportedComponents || []).indexOf("VTODO") >= 0)

    // ---------- dates ----------

    function pad(n) { return n < 10 ? "0" + n : "" + n; }

    function rfc3339(d) {
        const off = -d.getTimezoneOffset();
        const sign = off >= 0 ? "+" : "-";
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
            + "T" + pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds())
            + sign + pad(Math.floor(Math.abs(off) / 60)) + ":" + pad(Math.abs(off) % 60);
    }

    // For all-day events and task due dates Google returns midnight UTC: keep only the date
    function toDate(v, dateOnly) {
        if (!v)
            return null;
        if (dateOnly) {
            const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(v);
            if (m)
                return new Date(+m[1], +m[2] - 1, +m[3]);
        }
        const d = new Date(v);
        return isNaN(d.getTime()) ? null : d;
    }

    function startOfDay(d) {
        const x = new Date(d);
        x.setHours(0, 0, 0, 0);
        return x;
    }

    function daysFromToday(d) {
        return Math.round((startOfDay(d) - startOfDay(new Date())) / 86400000);
    }

    // forms: "one|other" in English, "one|few|many" in Russian translations
    function plural(n, forms) {
        const f = forms.split("|");
        let form = f[f.length - 1];
        if (f.length === 2) {
            form = n === 1 ? f[0] : f[1];
        } else if (f.length >= 3) {
            const m10 = n % 10, m100 = n % 100;
            form = m10 === 1 && m100 !== 11 ? f[0] : m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) ? f[1] : f[2];
        }
        return form.arg(n);
    }

    function dayLabel(d) {
        const diff = daysFromToday(d);
        if (diff === 0)
            return I18n.trFor("dcalAgenda", "Today");
        if (diff === 1)
            return I18n.trFor("dcalAgenda", "Tomorrow");
        const s = I18n.locale().toString(d, I18n.trFor("dcalAgenda", "dddd, MMMM d"));
        return s.charAt(0).toUpperCase() + s.slice(1);
    }

    function timeLabel(e) {
        if (e.allDay)
            return I18n.trFor("dcalAgenda", "all day");
        return Qt.formatTime(e.start, "HH:mm") + (e.end ? "–" + Qt.formatTime(e.end, "HH:mm") : "");
    }

    // ---------- now ----------

    // Re-evaluated every 30 s so "current" and "soon" follow the clock
    property real now: Date.now()
    readonly property int soonMinutes: pluginData.soonMinutes ?? 5
    readonly property bool pulseEnabled: (pluginData.pulseCurrent ?? true) && !SettingsData.reduceMotion

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.now = Date.now()
    }

    // "past" | "now" | "soon" (starts within soonMinutes) | ""
    function eventState(e) {
        if (e.allDay || !e.start)
            return "";
        const start = e.start.getTime();
        const end = e.end ? e.end.getTime() : start;
        if (now >= end)
            return "past";
        if (now >= start)
            return "now";
        if (now >= start - soonMinutes * 60000)
            return "soon";
        return "";
    }

    function eventBadge(e, st) {
        if (st === "now")
            return e.end ? I18n.trFor("dcalAgenda", "Now · until %1").arg(Qt.formatTime(e.end, "HH:mm")) : I18n.trFor("dcalAgenda", "Now");
        if (st === "soon")
            return plural(Math.max(1, Math.ceil((e.start.getTime() - now) / 60000)), I18n.trFor("dcalAgenda", "In %1 min|In %1 min"));
        return "";
    }

    // "11 weeks ago", "today", "tomorrow", "Fri, Oct 17"
    function dueLabel(d) {
        const diff = daysFromToday(d);
        if (diff === 0)
            return I18n.trFor("dcalAgenda", "today");
        if (diff === 1)
            return I18n.trFor("dcalAgenda", "tomorrow");
        if (diff === -1)
            return I18n.trFor("dcalAgenda", "yesterday");
        if (diff < 0) {
            const n = -diff;
            if (n < 14)
                return plural(n, I18n.trFor("dcalAgenda", "%1 day ago|%1 days ago"));
            if (n < 91) {
                const w = Math.floor(n / 7);
                return plural(w, I18n.trFor("dcalAgenda", "%1 week ago|%1 weeks ago"));
            }
            const mo = Math.floor(n / 30);
            return plural(mo, I18n.trFor("dcalAgenda", "%1 month ago|%1 months ago"));
        }
        return I18n.locale().toString(d, I18n.trFor("dcalAgenda", "ddd, MMM d"));
    }

    // ---------- data ----------

    function calendarById(id) {
        return calendars.find(c => c.id === id) || null;
    }

    function calendarColor(id) {
        const c = calendarById(id);
        return (c && c.color) ? c.color : Theme.primary;
    }

    function refresh() {
        calendarsProc.running = true;
        const from = startOfDay(new Date());
        const to = new Date(from.getTime() + root.daysAhead * 86400000);
        eventsProc.command = ["dcal", "ipc", "events.list", "from=" + rfc3339(from), "to=" + rfc3339(to), "limit=200"];
        eventsProc.running = true;
        tasksProc.running = true;
    }

    function parse(text, key) {
        try {
            const obj = JSON.parse(text);
            root.errorText = "";
            return Array.isArray(obj) ? obj : (obj[key] || []);
        } catch (e) {
            root.errorText = I18n.trFor("dcalAgenda", "dcal is not responding");
            return null;
        }
    }

    Process {
        id: calendarsProc
        command: ["dcal", "ipc", "calendars.list"]
        stdout: StdioCollector {
            onStreamFinished: {
                const list = root.parse(text, "calendars");
                if (list)
                    root.calendars = list.filter(c => !c.hidden && !c.syncDisabled);
            }
        }
    }

    Process {
        id: eventsProc
        stdout: StdioCollector {
            onStreamFinished: {
                const raw = root.parse(text, "events");
                if (!raw)
                    return;
                const list = raw.filter(e => e.status !== "cancelled").map(e => ({
                    uid: e.uid,
                    title: e.summary || I18n.trFor("dcalAgenda", "(no title)"),
                    allDay: !!e.allDay,
                    rawStart: e.start,
                    start: root.toDate(e.start, !!e.allDay),
                    end: e.allDay ? null : root.toDate(e.end, false),
                    calendarId: e.calendarId
                })).filter(e => e.start);
                list.sort((a, b) => a.start - b.start);
                root.events = list;
            }
        }
    }

    Process {
        id: tasksProc
        command: ["dcal", "ipc", "tasks.list", "includeCompleted=true", "limit=500"]
        stdout: StdioCollector {
            onStreamFinished: {
                const raw = root.parse(text, "tasks");
                if (!raw)
                    return;
                root.tasks = raw.filter(t => t.status !== "cancelled").map(t => ({
                    id: t.id,
                    title: t.summary || I18n.trFor("dcalAgenda", "(no title)"),
                    due: root.toDate(t.due, true),
                    done: t.status === "completed",
                    completedAt: root.toDate(t.completed, false),
                    calendarId: t.calendarId
                }));
            }
        }
    }

    // Changes (create / complete / reopen) run one at a time, then the lists refresh
    property var pendingCommands: []

    function runCommand(cmd) {
        pendingCommands = pendingCommands.concat([cmd]);
        if (!actionProc.running)
            nextCommand();
    }

    function nextCommand() {
        if (!pendingCommands.length) {
            refresh();
            return;
        }
        actionProc.command = pendingCommands[0];
        pendingCommands = pendingCommands.slice(1);
        actionProc.running = true;
    }

    Process {
        id: actionProc
        onExited: root.nextCommand()
    }

    function setTaskDone(task, done) {
        // update the view at once instead of waiting for dcal
        root.tasks = root.tasks.map(t => t.id === task.id ? Object.assign({}, t, { done: done, completedAt: done ? new Date() : null }) : t);
        runCommand(["dcal", "ipc", "tasks.complete", "id=" + task.id, "completed=" + done]);
    }

    // Google Tasks keeps only a date for a task, so send midnight UTC of that day
    function dueParam(d) {
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) + "T00:00:00Z";
    }

    function createTask(listId, title, due, description) {
        title = title.trim();
        if (!title)
            return;
        const cmd = ["dcal", "ipc", "tasks.create", "calendarId=" + listId, "summary=" + title];
        if (due)
            cmd.push("due=" + dueParam(due), "allDay=true");
        if (description && description.trim())
            cmd.push("description=" + description.trim());
        // show it in the list at once; dcal catches up on refresh
        root.tasks = root.tasks.concat([{ id: "pending-" + Date.now(), title: title, due: due, done: false, completedAt: null, calendarId: listId }]);
        runCommand(cmd);
    }

    function openEditor(listId) {
        root.editorList = listId;
        root.addingToList = listId;
    }

    property string editorList: ""

    // «12.10», «12.10.2026», «12/10» -> Date
    function parseUserDate(text) {
        const m = /^\s*(\d{1,2})[.\/-](\d{1,2})(?:[.\/-](\d{2,4}))?\s*$/.exec(text);
        if (!m)
            return null;
        const now = new Date();
        let y = m[3] ? +m[3] : now.getFullYear();
        if (y < 100)
            y += 2000;
        const d = new Date(y, +m[2] - 1, +m[1]);
        if (isNaN(d.getTime()) || d.getDate() !== +m[1])
            return null;
        // "12.01" without a year that has already passed means next year
        if (!m[3] && daysFromToday(d) < 0)
            d.setFullYear(y + 1);
        return d;
    }

    component Chip: Rectangle {
        id: chip
        property string label
        property bool selected: false
        signal clicked
        implicitHeight: chipText.implicitHeight + Theme.spacingXS * 2
        implicitWidth: chipText.implicitWidth + Theme.spacingM * 2
        radius: height / 2
        color: selected ? Theme.withAlpha(Theme.primary, 0.22) : (chipMouse.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.08) : "transparent")
        border.width: 1
        border.color: selected ? Theme.primary : Theme.withAlpha(Theme.surfaceText, 0.25)
        StyledText {
            id: chipText
            anchors.centerIn: parent
            text: chip.label
            font.pixelSize: Theme.fontSizeSmall
            color: chip.selected ? Theme.primary : Theme.surfaceText
        }
        MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
    }

    // New task editor: title, due date, description, list
    component TaskEditor: Rectangle {
        id: ed
        property var due: null
        property string dueMode: "none"   // none | today | tomorrow | week | custom

        implicitHeight: edCol.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: root.tileBg
        border.width: 1
        border.color: Theme.withAlpha(Theme.primary, 0.4)

        function reset() {
            titleInput.text = "";
            descInput.text = "";
            dateInput.text = "";
            due = null;
            dueMode = "none";
        }

        function setDue(mode) {
            dueMode = mode;
            const d = root.startOfDay(new Date());
            if (mode === "today")
                due = d;
            else if (mode === "tomorrow")
                due = new Date(d.getTime() + 86400000);
            else if (mode === "week")
                due = new Date(d.getTime() + 7 * 86400000);
            else if (mode === "none")
                due = null;
            if (mode !== "custom")
                dateInput.text = "";
        }

        function save() {
            if (!titleInput.text.trim())
                return;
            root.createTask(root.editorList, titleInput.text, due, descInput.text);
            close();
        }

        function close() {
            reset();
            root.addingToList = "";
        }

        onVisibleChanged: if (visible) { reset(); titleInput.forceActiveFocus(); }

        ColumnLayout {
            id: edCol
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingM

            // Title
            Column {
                Layout.fillWidth: true
                spacing: 4
                TextInput {
                    id: titleInput
                    width: parent.width
                    font.pixelSize: Theme.fontSizeLarge
                    font.family: Theme.fontFamily
                    color: Theme.surfaceText
                    selectionColor: Theme.primary
                    clip: true
                    onAccepted: ed.save()
                    Keys.onEscapePressed: ed.close()
                    StyledText {
                        visible: !titleInput.text
                        text: I18n.trFor("dcalAgenda", "Add a title")
                        font.pixelSize: Theme.fontSizeLarge
                        color: Theme.surfaceTextSecondary
                    }
                }
                Rectangle { width: parent.width; height: 1; color: titleInput.activeFocus ? Theme.primary : Theme.outlineVariant }
            }

            // Due date
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingS
                DankIcon { name: "schedule"; size: Theme.iconSize - 4; color: Theme.surfaceTextSecondary; Layout.alignment: Qt.AlignTop; Layout.topMargin: 4 }
                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.spacingXS
                    Chip { label: I18n.trFor("dcalAgenda", "No date"); selected: ed.dueMode === "none"; onClicked: ed.setDue("none") }
                    Chip { label: I18n.trFor("dcalAgenda", "Today"); selected: ed.dueMode === "today"; onClicked: ed.setDue("today") }
                    Chip { label: I18n.trFor("dcalAgenda", "Tomorrow"); selected: ed.dueMode === "tomorrow"; onClicked: ed.setDue("tomorrow") }
                    Chip { label: I18n.trFor("dcalAgenda", "In a week"); selected: ed.dueMode === "week"; onClicked: ed.setDue("week") }
                    // own date: dd.mm or dd.mm.yyyy
                    Rectangle {
                        implicitHeight: dateInput.implicitHeight + Theme.spacingXS * 2
                        implicitWidth: 110
                        radius: height / 2
                        color: ed.dueMode === "custom" ? Theme.withAlpha(Theme.primary, 0.22) : "transparent"
                        border.width: 1
                        border.color: ed.dueMode === "custom" ? Theme.primary : Theme.withAlpha(Theme.surfaceText, 0.25)
                        TextInput {
                            id: dateInput
                            anchors.fill: parent
                            anchors.leftMargin: Theme.spacingM
                            anchors.rightMargin: Theme.spacingS
                            verticalAlignment: TextInput.AlignVCenter
                            font.pixelSize: Theme.fontSizeSmall
                            font.family: Theme.fontFamily
                            color: Theme.primary
                            clip: true
                            onTextEdited: {
                                const d = root.parseUserDate(text);
                                if (d) { ed.due = d; ed.dueMode = "custom"; }
                                else if (!text) ed.setDue("none");
                            }
                            onAccepted: ed.save()
                            Keys.onEscapePressed: ed.close()
                            StyledText {
                                visible: !dateInput.text
                                anchors.verticalCenter: parent.verticalCenter
                                text: I18n.trFor("dcalAgenda", "dd.mm")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceTextSecondary
                            }
                        }
                    }
                }
            }
            StyledText {
                visible: !!ed.due
                Layout.leftMargin: Theme.iconSize + Theme.spacingS - 4
                text: ed.due ? I18n.trFor("dcalAgenda", "Due %1").arg(I18n.locale().toString(ed.due, I18n.trFor("dcalAgenda", "dddd, MMMM d, yyyy"))) : ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceTextSecondary
            }

            // Description
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingS
                DankIcon { name: "notes"; size: Theme.iconSize - 4; color: Theme.surfaceTextSecondary; Layout.alignment: Qt.AlignTop; Layout.topMargin: Theme.spacingS }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: Math.max(64, descInput.implicitHeight + Theme.spacingS * 2)
                    radius: Theme.cornerRadius / 2
                    color: Theme.withAlpha(Theme.surfaceText, 0.06)
                    TextEdit {
                        id: descInput
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        font.pixelSize: Theme.fontSizeMedium
                        font.family: Theme.fontFamily
                        color: Theme.surfaceText
                        selectionColor: Theme.primary
                        wrapMode: TextEdit.Wrap
                        Keys.onEscapePressed: ed.close()
                        StyledText {
                            visible: !descInput.text
                            text: I18n.trFor("dcalAgenda", "Add a description")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceTextSecondary
                        }
                    }
                }
            }

            // List (when there are several)
            RowLayout {
                visible: root.taskLists.length > 1
                Layout.fillWidth: true
                spacing: Theme.spacingS
                DankIcon { name: "list"; size: Theme.iconSize - 4; color: Theme.surfaceTextSecondary }
                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.spacingXS
                    Repeater {
                        model: root.taskLists
                        delegate: Chip {
                            required property var modelData
                            label: root.listName(modelData)
                            selected: root.editorList === modelData.id
                            onClicked: root.editorList = modelData.id
                        }
                    }
                }
            }

            // Buttons
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingS
                Item { Layout.fillWidth: true }
                Chip { label: I18n.trFor("dcalAgenda", "Cancel"); onClicked: ed.close() }
                Rectangle {
                    implicitHeight: saveText.implicitHeight + Theme.spacingS * 2
                    implicitWidth: saveText.implicitWidth + Theme.spacingL * 2
                    radius: height / 2
                    readonly property bool ready: titleInput.text.trim() !== ""
                    color: ready ? Theme.primary : Theme.withAlpha(Theme.surfaceText, 0.12)
                    StyledText {
                        id: saveText
                        anchors.centerIn: parent
                        text: I18n.trFor("dcalAgenda", "Save")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: parent.ready ? Theme.primaryText : Theme.surfaceTextSecondary
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: parent.ready ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: ed.save()
                    }
                }
            }
        }
    }

    function listName(c) {
        return /'s list$/.test(c.name) ? I18n.trFor("dcalAgenda", "My Tasks") : c.name;
    }

    function toggleCalendar(id) {
        const hidden = hiddenCalendars.indexOf(id) >= 0 ? hiddenCalendars.filter(x => x !== id) : hiddenCalendars.concat([id]);
        hiddenCalendars = hidden;
        if (pluginService && pluginService.savePluginData)
            pluginService.savePluginData(pluginId, "hiddenCalendars", hidden);
    }

    Timer {
        interval: root.refreshMinutes * 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.refresh();
            statusProc.running = true;
        }
    }

    // ---------- sync ----------
    // dcal syncs the account about once a minute and logs errors to the systemd journal.
    // syncState: idle | syncing | ok | error

    property string syncState: "idle"
    property string syncError: ""
    property date lastOk

    function syncErrorText(line) {
        if (/retry deferred|rateLimit|quota/i.test(line))
            return I18n.trFor("dcalAgenda", "Google rate limit");
        if (/auth|token|401|invalid_grant/i.test(line))
            return I18n.trFor("dcalAgenda", "Google sign-in needed");
        if (/dial|timeout|network|no such host/i.test(line))
            return I18n.trFor("dcalAgenda", "offline");
        return I18n.trFor("dcalAgenda", "sync error");
    }

    function applySyncResult(text) {
        const line = text.trim();
        if (line) {
            root.syncState = "error";
            root.syncError = syncErrorText(line);
        } else {
            root.syncState = "ok";
            root.syncError = "";
            root.lastOk = new Date();
        }
    }

    function syncNow() {
        if (syncProc.running)
            return;
        root.syncState = "syncing";
        syncProc.running = true;
    }

    // Manual sync: start it, wait, then look for errors logged meanwhile
    Process {
        id: syncProc
        command: ["sh", "-c", "dcal ipc accounts.refresh >/dev/null 2>&1; sleep 8; journalctl --user -u dcal --since -12s -o cat 2>/dev/null | grep 'sync error' | tail -n1"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.applySyncResult(text);
                root.refresh();
            }
        }
    }

    // Background check: any sync errors in the last 3 minutes
    Process {
        id: statusProc
        command: ["sh", "-c", "journalctl --user -u dcal --since -3min -o cat 2>/dev/null | grep 'sync error' | tail -n1"]
        stdout: StdioCollector {
            onStreamFinished: if (root.syncState !== "syncing") root.applySyncResult(text)
        }
    }

    // Sync icon and status for the headers
    component SyncButton: RowLayout {
        spacing: Theme.spacingXS
        StyledText {
            text: root.syncState === "syncing" ? I18n.trFor("dcalAgenda", "syncing…")
                : root.syncState === "error" ? root.syncError
                : root.syncState === "ok" ? I18n.trFor("dcalAgenda", "synced %1").arg(Qt.formatTime(root.lastOk, "HH:mm")) : ""
            font.pixelSize: Theme.fontSizeSmall
            color: root.syncState === "error" ? Theme.error : Theme.surfaceTextSecondary
        }
        Rectangle {
            implicitWidth: Theme.iconSize + Theme.spacingS
            implicitHeight: implicitWidth
            radius: width / 2
            color: syncMouse.containsMouse ? Theme.withAlpha(Theme.primary, 0.18) : "transparent"
            DankIcon {
                id: syncIcon
                anchors.centerIn: parent
                name: root.syncState === "error" ? "sync_problem" : "sync"
                size: Theme.iconSize - 4
                color: root.syncState === "error" ? Theme.error : Theme.primary
                RotationAnimation on rotation {
                    running: root.syncState === "syncing"
                    from: 0; to: -360; duration: 1000
                    loops: Animation.Infinite
                    onStopped: syncIcon.rotation = 0
                }
            }
            MouseArea {
                id: syncMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.syncNow()
            }
        }
    }

    // events of the shown calendars grouped by day; days without events are skipped
    readonly property var eventGroups: {
        const groups = [];
        for (const e of events) {
            if (hiddenCalendars.indexOf(e.calendarId) >= 0)
                continue;
            const label = dayLabel(e.start);
            if (!groups.length || groups[groups.length - 1].day !== label)
                groups.push({ day: label, items: [] });
            groups[groups.length - 1].items.push(e);
        }
        return groups;
    }

    function openTasks(listId) {
        const list = tasks.filter(t => t.calendarId === listId && !t.done);
        // as in Google: tasks with a due date first (earliest on top), then the rest
        list.sort((a, b) => (a.due ? a.due.getTime() : 8.64e15) - (b.due ? b.due.getTime() : 8.64e15));
        return list;
    }

    function doneTasks(listId) {
        const list = tasks.filter(t => t.calendarId === listId && t.done);
        list.sort((a, b) => (b.completedAt ? b.completedAt.getTime() : 0) - (a.completedAt ? a.completedAt.getTime() : 0));
        return list;
    }

    // ---------- shared components ----------

    component HeaderButton: Rectangle {
        id: hb
        property string icon
        property string label
        signal clicked
        implicitHeight: hbRow.implicitHeight + Theme.spacingXS * 2
        implicitWidth: hbRow.implicitWidth + Theme.spacingM * 2
        radius: height / 2
        color: hbMouse.containsMouse ? Theme.withAlpha(Theme.primary, 0.18) : Theme.withAlpha(Theme.primary, 0.10)

        RowLayout {
            id: hbRow
            anchors.centerIn: parent
            spacing: Theme.spacingXS
            DankIcon { name: hb.icon; size: Theme.iconSize - 4; color: Theme.primary }
            StyledText { text: hb.label; font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Medium; color: Theme.primary }
        }
        MouseArea {
            id: hbMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: hb.clicked()
        }
    }

    // ---------- view ----------

    property bool isCollapsed: false
    readonly property real tabWidth: 28

    Item {
        id: slidingRoot
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: root.width

        x: root.isCollapsed ? (root.width - root.tabWidth) : 0

        Behavior on x {
            NumberAnimation {
                duration: 250
                easing.type: Easing.InOutCubic
            }
        }

        Rectangle {
            id: toggleTab
            width: root.tabWidth
            height: 52
            x: 0
            y: 30
            color: root.bgColor
            topLeftRadius: 16
            bottomLeftRadius: 16
            topRightRadius: 0
            bottomRightRadius: 0

            DankIcon {
                anchors.centerIn: parent
                name: root.isCollapsed ? "chevron_left" : "chevron_right"
                size: Theme.iconSizeSmall
                color: Theme.primary
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.isCollapsed = !root.isCollapsed
            }
        }

        Rectangle {
            id: calendarBody
            x: root.tabWidth
            width: root.width - root.tabWidth
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            radius: Theme.cornerRadius
            color: root.bgColor
            clip: true

        RowLayout {
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingL

            // ===== Calendar =====
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                spacing: Theme.spacingS

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingS
                    DankIcon { name: "calendar_month"; size: Theme.iconSize; color: Theme.primary }
                    StyledText { text: I18n.trFor("dcalAgenda", "Calendar"); font.pixelSize: Theme.fontSizeLarge; font.weight: Font.Medium; color: Theme.surfaceText }
                    Item { Layout.fillWidth: true }
                    SyncButton {}
                    HeaderButton {
                        icon: "add"
                        label: I18n.trFor("dcalAgenda", "Event")
                        onClicked: root.runCommand(["dcal", "ipc", "ui.newEvent"])
                    }
                }

                // Calendar filter: click to hide or show
                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.spacingXS
                    visible: root.eventCalendars.length > 1

                    Repeater {
                        model: root.eventCalendars
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool shown: root.hiddenCalendars.indexOf(modelData.id) < 0
                            height: chipRow.implicitHeight + Theme.spacingXS * 2
                            width: chipRow.implicitWidth + Theme.spacingS * 2
                            radius: height / 2
                            color: shown ? Theme.withAlpha(modelData.color || Theme.primary, 0.18) : "transparent"
                            border.width: 1
                            border.color: Theme.withAlpha(modelData.color || Theme.primary, shown ? 0.5 : 0.25)

                            RowLayout {
                                id: chipRow
                                anchors.centerIn: parent
                                spacing: Theme.spacingXS
                                Rectangle { width: 8; height: 8; radius: 4; color: modelData.color || Theme.primary; opacity: parent.parent.shown ? 1 : 0.4 }
                                StyledText {
                                    text: modelData.name.indexOf("@") > 0 ? I18n.trFor("dcalAgenda", "Mine") : modelData.name
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: parent.parent.shown ? Theme.surfaceText : Theme.surfaceTextSecondary
                                    font.strikeout: !parent.parent.shown
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleCalendar(modelData.id)
                            }
                        }
                    }
                }

                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: Theme.spacingM
                    model: root.eventGroups

                    delegate: Column {
                        required property var modelData
                        width: ListView.view.width
                        spacing: Theme.spacingXS

                        StyledText {
                            text: modelData.day
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.primary
                        }

                        Repeater {
                            model: modelData.items
                            delegate: Rectangle {
                                id: eventCard
                                required property var modelData
                                readonly property string evState: root.eventState(modelData)
                                readonly property bool active: evState === "now" || evState === "soon"
                                width: parent.width
                                height: evCol.implicitHeight + Theme.spacingS * 2
                                radius: Theme.cornerRadius / 2
                                // Current and upcoming: a light tint of the theme color; finished: faded
                                color: evMouse.containsMouse ? Theme.withAlpha(Theme.primary, 0.2)
                                    : evState === "now" ? Theme.withAlpha(Theme.primary, 0.16)
                                    : evState === "soon" ? Theme.withAlpha(Theme.primary, 0.09)
                                    : root.tileBg
                                border.width: evState === "now" ? 1 : 0
                                border.color: Theme.withAlpha(Theme.primary, 0.45)
                                opacity: evState === "past" ? 0.5 : 1

                                Behavior on color { ColorAnimation { duration: 400 } }
                                Behavior on opacity { NumberAnimation { duration: 400 } }

                                // Attention: a few slow, soft glows when the event becomes upcoming or
                                // current, repeated every 10 minutes while it runs, then calm. Never a
                                // hard blink; off with the setting or with reduced motion.
                                Rectangle {
                                    id: glow
                                    anchors.fill: parent
                                    radius: parent.radius
                                    color: Theme.primary
                                    opacity: 0
                                }
                                SequentialAnimation {
                                    id: glowAnim
                                    loops: 3
                                    NumberAnimation { target: glow; property: "opacity"; to: 0.16; duration: 1200; easing.type: Easing.InOutSine }
                                    NumberAnimation { target: glow; property: "opacity"; to: 0; duration: 1200; easing.type: Easing.InOutSine }
                                }
                                function attention() {
                                    if (root.pulseEnabled && active)
                                        glowAnim.restart();
                                }
                                onEvStateChanged: attention()
                                Component.onCompleted: attention()
                                Timer {
                                    interval: 600000
                                    running: eventCard.evState === "now" && root.pulseEnabled
                                    repeat: true
                                    onTriggered: eventCard.attention()
                                }

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    anchors.margins: Theme.spacingS
                                    width: eventCard.evState === "now" ? 6 : 4
                                    radius: width / 2
                                    color: root.calendarColor(modelData.calendarId)
                                }

                                ColumnLayout {
                                    id: evCol
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingS * 2 + 6
                                    anchors.rightMargin: Theme.spacingS
                                    spacing: 0

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.spacingS
                                        StyledText {
                                            text: modelData.title
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: eventCard.evState === "now" ? Font.Medium : Font.Normal
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                        // "Now · until 18:30" / "In 3 min" with a small dot
                                        Rectangle {
                                            visible: eventCard.active
                                            implicitHeight: badgeRow.implicitHeight + 4
                                            implicitWidth: badgeRow.implicitWidth + Theme.spacingS * 2
                                            radius: height / 2
                                            color: eventCard.evState === "now" ? Theme.primary : Theme.withAlpha(Theme.primary, 0.18)
                                            RowLayout {
                                                id: badgeRow
                                                anchors.centerIn: parent
                                                spacing: 4
                                                Rectangle {
                                                    width: 6; height: 6; radius: 3
                                                    color: eventCard.evState === "now" ? Theme.primaryText : Theme.primary
                                                }
                                                StyledText {
                                                    text: root.eventBadge(eventCard.modelData, eventCard.evState)
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    font.weight: Font.Medium
                                                    color: eventCard.evState === "now" ? Theme.primaryText : Theme.primary
                                                }
                                            }
                                        }
                                    }
                                    StyledText {
                                        readonly property var cal: root.calendarById(modelData.calendarId)
                                        text: root.timeLabel(modelData) + (cal && cal.name.indexOf("@") < 0 ? "  ·  " + cal.name : "")
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceTextSecondary
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                }

                                MouseArea {
                                    id: evMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.runCommand(["dcal", "ipc", "ui.openEvent", "uid=" + modelData.uid, "start=" + modelData.rawStart])
                                }
                            }
                        }
                    }

                    StyledText {
                        anchors.centerIn: parent
                        visible: root.eventGroups.length === 0
                        text: root.errorText || root.plural(root.daysAhead, I18n.trFor("dcalAgenda", "No events in the next %1 day|No events in the next %1 days"))
                        color: Theme.surfaceTextSecondary
                        font.pixelSize: Theme.fontSizeMedium
                    }
                }
            }

            Rectangle {
                Layout.preferredWidth: 1
                Layout.fillHeight: true
                color: Theme.outlineVariant
                opacity: 0.5
            }

            // ===== Tasks =====
            Flickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                clip: true
                contentHeight: tasksCol.implicitHeight
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: tasksCol
                    width: parent.width
                    spacing: Theme.spacingL

                    StyledText {
                        visible: root.taskLists.length === 0
                        text: root.errorText || I18n.trFor("dcalAgenda", "No task lists")
                        color: Theme.surfaceTextSecondary
                        font.pixelSize: Theme.fontSizeMedium
                    }

                    Repeater {
                        model: root.taskLists

                        delegate: ColumnLayout {
                            id: listBlock
                            required property var modelData
                            required property int index
                            readonly property var open: root.openTasks(modelData.id)
                            readonly property var done: root.doneTasks(modelData.id)
                            readonly property bool doneExpanded: !!root.expandedDone[modelData.id]
                            Layout.fillWidth: true
                            spacing: Theme.spacingXS

                            // List name
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.bottomMargin: Theme.spacingXS
                                spacing: Theme.spacingS
                                DankIcon { name: "task_alt"; size: Theme.iconSize; color: Theme.primary }
                                StyledText {
                                    text: root.listName(listBlock.modelData)
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                StyledText {
                                    visible: listBlock.open.length > 0
                                    text: listBlock.open.length
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceTextSecondary
                                }
                                SyncButton { visible: listBlock.index === 0 }
                            }

                            // Add task: a button row that opens the editor, as in Google
                            Rectangle {
                                visible: root.addingToList !== listBlock.modelData.id
                                Layout.fillWidth: true
                                implicitHeight: addRow.implicitHeight + Theme.spacingS * 2
                                radius: Theme.cornerRadius / 2
                                color: addMouse.containsMouse ? Theme.withAlpha(Theme.primary, 0.10) : "transparent"

                                RowLayout {
                                    id: addRow
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingS
                                    spacing: Theme.spacingS
                                    DankIcon { name: "add_task"; size: Theme.iconSize - 2; color: Theme.primary }
                                    StyledText {
                                        text: I18n.trFor("dcalAgenda", "Add task")
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.primary
                                        Layout.fillWidth: true
                                    }
                                }
                                MouseArea {
                                    id: addMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.openEditor(listBlock.modelData.id)
                                }
                            }

                            TaskEditor {
                                visible: root.addingToList === listBlock.modelData.id
                                Layout.fillWidth: true
                            }

                            // Open tasks, overdue ones included
                            Repeater {
                                model: listBlock.open
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property int dueIn: modelData.due ? (root.now, root.daysFromToday(modelData.due)) : 1
                                    readonly property bool overdue: !!modelData.due && dueIn < 0
                                    readonly property bool dueToday: !!modelData.due && dueIn === 0
                                    Layout.fillWidth: true
                                    implicitHeight: taskRow.implicitHeight + Theme.spacingS * 2
                                    radius: Theme.cornerRadius / 2
                                    // Due today: light theme tint; overdue: light red. Tasks have no time
                                    // of day, so they never animate; color alone sets them apart.
                                    color: taskMouse.containsMouse ? Theme.withAlpha(Theme.primary, 0.14)
                                        : dueToday ? Theme.withAlpha(Theme.primary, 0.11)
                                        : overdue ? Theme.withAlpha(Theme.error, 0.08)
                                        : "transparent"

                                    RowLayout {
                                        id: taskRow
                                        anchors.fill: parent
                                        anchors.margins: Theme.spacingS
                                        spacing: Theme.spacingS

                                        DankIcon {
                                            Layout.alignment: Qt.AlignTop
                                            name: checkMouse.containsMouse ? "check_circle" : "radio_button_unchecked"
                                            size: Theme.iconSize - 2
                                            color: checkMouse.containsMouse ? Theme.primary : Theme.surfaceTextSecondary
                                            MouseArea {
                                                id: checkMouse
                                                anchors.fill: parent
                                                anchors.margins: -4
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.setTaskDone(modelData, true)
                                            }
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.spacingXS
                                            StyledText {
                                                text: modelData.title
                                                font.pixelSize: Theme.fontSizeMedium
                                                color: Theme.surfaceText
                                                wrapMode: Text.Wrap
                                                Layout.fillWidth: true
                                            }
                                            // due date chip
                                            Rectangle {
                                                visible: !!modelData.due
                                                implicitHeight: dueRow.implicitHeight + 4
                                                implicitWidth: dueRow.implicitWidth + Theme.spacingS * 2
                                                radius: height / 2
                                                color: "transparent"
                                                border.width: 1
                                                border.color: overdue ? Theme.withAlpha(Theme.error, 0.6) : dueToday ? Theme.withAlpha(Theme.primary, 0.7) : Theme.withAlpha(Theme.surfaceText, 0.25)
                                                RowLayout {
                                                    id: dueRow
                                                    anchors.centerIn: parent
                                                    spacing: 4
                                                    DankIcon { name: "schedule"; size: Theme.fontSizeSmall + 2; color: overdue ? Theme.error : dueToday ? Theme.primary : Theme.surfaceTextSecondary }
                                                    StyledText {
                                                        text: modelData.due ? root.dueLabel(modelData.due) : ""
                                                        font.pixelSize: Theme.fontSizeSmall
                                                        color: overdue ? Theme.error : dueToday ? Theme.primary : Theme.surfaceTextSecondary
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    MouseArea {
                                        id: taskMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        acceptedButtons: Qt.NoButton
                                    }
                                }
                            }

                            StyledText {
                                visible: listBlock.open.length === 0
                                text: I18n.trFor("dcalAgenda", "All tasks complete 🎉")
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceTextSecondary
                                Layout.leftMargin: Theme.spacingS
                            }

                            // Completed tasks in a collapsed block
                            Rectangle {
                                visible: listBlock.done.length > 0
                                Layout.fillWidth: true
                                Layout.topMargin: Theme.spacingS
                                implicitHeight: doneHeader.implicitHeight + Theme.spacingS * 2
                                radius: Theme.cornerRadius / 2
                                color: doneMouse.containsMouse ? Theme.withAlpha(Theme.primary, 0.08) : "transparent"

                                RowLayout {
                                    id: doneHeader
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingS
                                    spacing: Theme.spacingS
                                    DankIcon {
                                        name: listBlock.doneExpanded ? "expand_more" : "chevron_right"
                                        size: Theme.iconSize - 2
                                        color: Theme.surfaceTextSecondary
                                    }
                                    StyledText {
                                        readonly property int n: listBlock.done.length
                                        text: root.plural(n, I18n.trFor("dcalAgenda", "%1 task completed|%1 tasks completed"))
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceTextSecondary
                                        Layout.fillWidth: true
                                    }
                                }
                                MouseArea {
                                    id: doneMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        const e = Object.assign({}, root.expandedDone);
                                        e[listBlock.modelData.id] = !listBlock.doneExpanded;
                                        root.expandedDone = e;
                                    }
                                }
                            }

                            Repeater {
                                model: listBlock.doneExpanded ? listBlock.done : []
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Theme.spacingS
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        Layout.alignment: Qt.AlignTop
                                        name: "check"
                                        size: Theme.iconSize - 2
                                        color: Theme.primary
                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -4
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.setTaskDone(modelData, false)
                                        }
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 0
                                        StyledText {
                                            text: modelData.title
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.strikeout: true
                                            color: Theme.surfaceTextSecondary
                                            wrapMode: Text.Wrap
                                            Layout.fillWidth: true
                                        }
                                        StyledText {
                                            visible: !!modelData.completedAt
                                            text: modelData.completedAt ? I18n.trFor("dcalAgenda", "Completed %1").arg(I18n.locale().toString(modelData.completedAt, I18n.trFor("dcalAgenda", "ddd, MMM d"))) : ""
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceTextSecondary
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    }
}
