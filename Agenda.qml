import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.DCommon.Widgets
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
    // Tasks whose subtasks are shown; the rest stay collapsed, which is the default
    property var expandedTasks: pluginData.expandedTasks ?? []
    property bool doneExpanded: false   // whether the completed block is expanded
    // Task lists switched off with the chips in the header
    property var hiddenTaskLists: pluginData.hiddenTaskLists ?? []
    readonly property var visibleTaskLists: taskLists.filter(c => hiddenTaskLists.indexOf(c.id) < 0)
    property string errorText: ""

    // While the task editor is open the widget takes keyboard input
    // Where the task editor is open: "" (closed), "new" (top of the column) or
    // the uid of the task getting a subtask
    property string editorAt: ""
    property var editorParent: null
    property bool acceptsKeyboardFocus: editorAt !== ""

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
                    uid: t.uid || "",
                    parentUid: t.parentUid || "",
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
        // As in Google, completing a task completes its open subtasks too
        const ids = [task.id];
        if (done && task.uid)
            for (const t of root.tasks)
                if (t.parentUid === task.uid && !t.done)
                    ids.push(t.id);
        // update the view at once instead of waiting for dcal
        root.tasks = root.tasks.map(t => ids.indexOf(t.id) >= 0 ? Object.assign({}, t, { done: done, completedAt: done ? new Date() : null }) : t);
        for (const id of ids)
            runCommand(["dcal", "ipc", "tasks.complete", "id=" + id, "completed=" + done]);
    }

    // Google Tasks keeps only a date for a task, so send midnight UTC of that day
    function dueParam(d) {
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) + "T00:00:00Z";
    }

    function createTask(listId, title, due, description, parentUid) {
        title = title.trim();
        if (!title)
            return;
        const cmd = ["dcal", "ipc", "tasks.create", "calendarId=" + listId, "summary=" + title];
        if (parentUid)
            cmd.push("parentUid=" + parentUid);
        if (due)
            cmd.push("due=" + dueParam(due), "allDay=true");
        if (description && description.trim())
            cmd.push("description=" + description.trim());
        // show it in the list at once; dcal catches up on refresh
        root.tasks = root.tasks.concat([{ id: "pending-" + Date.now(), uid: "", parentUid: parentUid || "", title: title, due: due, done: false, completedAt: null, calendarId: listId }]);
        runCommand(cmd);
    }

    function openEditor(listId) {
        root.editorList = listId || (visibleTaskLists[0] ?? taskLists[0])?.id || "";
        root.editorParent = null;
        root.editorAt = "new";
    }

    // A subtask goes into the parent's list
    function openSubtaskEditor(parent) {
        root.editorList = parent.calendarId;
        root.editorParent = parent;
        root.editorAt = parent.uid;
        if (expandedTasks.indexOf(parent.uid) < 0)
            toggleSubtasks(parent.uid);
    }

    function toggleTaskList(id) {
        const hidden = hiddenTaskLists.indexOf(id) >= 0 ? hiddenTaskLists.filter(x => x !== id) : hiddenTaskLists.concat([id]);
        hiddenTaskLists = hidden;
        if (pluginService && pluginService.savePluginData)
            pluginService.savePluginData(pluginId, "hiddenTaskLists", hidden);
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
            root.createTask(root.editorList, titleInput.text, due, descInput.text, root.editorParent ? root.editorParent.uid : "");
            close();
        }

        function close() {
            reset();
            root.editorAt = "";
            root.editorParent = null;
        }

        onVisibleChanged: if (visible) { reset(); titleInput.forceActiveFocus(); }

        ColumnLayout {
            id: edCol
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingM

            StyledText {
                visible: !!root.editorParent
                Layout.fillWidth: true
                text: root.editorParent ? I18n.trFor("dcalAgenda", "Subtask of “%1”").arg(root.editorParent.title) : ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.primary
                elide: Text.ElideRight
            }

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
                DIcon { name: "schedule"; size: Theme.iconSize - 4; color: Theme.surfaceTextSecondary; Layout.alignment: Qt.AlignTop; Layout.topMargin: 4 }
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
                DIcon { name: "notes"; size: Theme.iconSize - 4; color: Theme.surfaceTextSecondary; Layout.alignment: Qt.AlignTop; Layout.topMargin: Theme.spacingS }
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
                visible: root.taskLists.length > 1 && !root.editorParent
                Layout.fillWidth: true
                spacing: Theme.spacingS
                DIcon { name: "list"; size: Theme.iconSize - 4; color: Theme.surfaceTextSecondary }
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

    function toggleSubtasks(uid) {
        const expanded = expandedTasks.indexOf(uid) >= 0 ? expandedTasks.filter(x => x !== uid) : expandedTasks.concat([uid]);
        expandedTasks = expanded;
        if (pluginService && pluginService.savePluginData)
            pluginService.savePluginData(pluginId, "expandedTasks", expanded);
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
            DIcon {
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

    // ---------- tasks by day ----------

    readonly property var shownTasks: {
        const lists = visibleTaskLists.map(c => c.id);
        return tasks.filter(t => lists.indexOf(t.calendarId) >= 0);
    }

    function byDue(a, b) {
        return (a.due ? a.due.getTime() : 8.64e15) - (b.due ? b.due.getTime() : 8.64e15);
    }

    function byCompleted(a, b) {
        return (b.completedAt ? b.completedAt.getTime() : 0) - (a.completedAt ? a.completedAt.getTime() : 0);
    }

    // One card per open top-level task with all its subtasks: open ones first,
    // then the completed ones, struck out, as in Google Tasks. An open subtask
    // of a completed task gets a card of its own and names its parent.
    readonly property var openGroups: {
        const byUid = {};
        for (const t of shownTasks)
            if (t.uid)
                byUid[t.uid] = t;
        const isOpenChild = t => t.parentUid && byUid[t.parentUid] && !byUid[t.parentUid].done;
        const tops = shownTasks.filter(t => !t.done && !isOpenChild(t)).sort(byDue);
        return tops.map(t => {
            const parent = t.parentUid ? byUid[t.parentUid] : null;
            const kids = shownTasks.filter(c => t.uid && c.parentUid === t.uid);
            const open = kids.filter(c => !c.done).sort(byDue);
            const done = kids.filter(c => c.done).sort(byCompleted);
            return {
                task: Object.assign({}, t, { parentTitle: parent ? parent.title : "" }),
                children: open.map(c => Object.assign({}, c, { parentTitle: "" })).concat(done.map(c => Object.assign({}, c, { parentTitle: "" }))),
                openChildren: open.length
            };
        });
    }

    // Sections like the calendar's days: overdue, today, tomorrow, later
    // dates, and last the tasks without a date
    readonly property var taskDays: {
        now;
        const days = [];
        const find = (key, label, kind) => {
            let d = days.find(x => x.key === key);
            if (!d) {
                d = { key: key, label: label, kind: kind, groups: [] };
                days.push(d);
            }
            return d;
        };
        for (const g of openGroups) {
            const due = g.task.due;
            if (!due)
                continue;
            const diff = daysFromToday(due);
            if (diff < 0)
                find("overdue", I18n.trFor("dcalAgenda", "Overdue"), "overdue").groups.push(g);
            else
                find("d" + diff, dayLabel(due), diff === 0 ? "today" : "").groups.push(g);
        }
        const undated = openGroups.filter(g => !g.task.due);
        if (undated.length)
            days.push({ key: "none", label: I18n.trFor("dcalAgenda", "No date"), kind: "", groups: undated });
        return days;
    }

    // Completed tasks for the collapsed block: those not already shown inside
    // an open task's card
    readonly property var doneList: {
        const byUid = {};
        for (const t of shownTasks)
            if (t.uid)
                byUid[t.uid] = t;
        return shownTasks.filter(t => t.done && !(t.parentUid && byUid[t.parentUid] && !byUid[t.parentUid].done))
            .sort(byCompleted)
            .map(t => Object.assign({}, t, { parentTitle: t.parentUid && byUid[t.parentUid] ? byUid[t.parentUid].title : "" }));
    }

    function listOf(t) {
        const c = taskLists.find(x => x.id === t.calendarId);
        return c ? listName(c) : "";
    }

    // "overdue" | "today" | "": the due state of one open task
    function dueState(t) {
        if (!t.due || t.done)
            return "";
        const days = (now, daysFromToday(t.due));
        return days < 0 ? "overdue" : days === 0 ? "today" : "";
    }

    // The most urgent state in a group, for the stripe on its card
    function groupState(g) {
        const states = [g.task].concat(g.children).map(dueState);
        return states.indexOf("overdue") >= 0 ? "overdue" : states.indexOf("today") >= 0 ? "today" : "";
    }

    // ---------- shared components ----------

    // One open task: check circle, title, parent hint, due chip. Its own tint
    // shows its due state, and it lights up under the pointer.
    component TaskRow: Rectangle {
        id: row
        required property var task
        property int subtaskCount: 0
        property string listCaption: ""
        property int subtasksDue: 0
        property bool expanded: false
        signal toggleSubtasks
        readonly property string due: root.dueState(task)
        readonly property bool hovered: rowHover.hovered

        implicitHeight: taskRow.implicitHeight + Theme.spacingS * 2
        radius: Theme.cornerRadius / 2
        // Due today: light theme tint; overdue: light red. Tasks have no time
        // of day, so they never animate; color alone sets them apart.
        color: hovered ? Theme.withAlpha(Theme.primary, 0.14)
            : due === "today" ? Theme.withAlpha(Theme.primary, 0.11)
            : due === "overdue" ? Theme.withAlpha(Theme.error, 0.09)
            : "transparent"
        Behavior on color { ColorAnimation { duration: 150 } }

        HoverHandler { id: rowHover }

        RowLayout {
            id: taskRow
            anchors.fill: parent
            anchors.margins: Theme.spacingS
            spacing: Theme.spacingS

            DIcon {
                Layout.alignment: Qt.AlignTop
                name: row.task.done ? (checkMouse.containsMouse ? "radio_button_unchecked" : "check") : (checkMouse.containsMouse ? "check_circle" : "radio_button_unchecked")
                size: Theme.iconSize - 2
                color: row.task.done || checkMouse.containsMouse ? Theme.primary : Theme.surfaceTextSecondary
                MouseArea {
                    id: checkMouse
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setTaskDone(row.task, !row.task.done)
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingXS
                StyledText {
                    text: row.task.title
                    font.pixelSize: Theme.fontSizeMedium
                    font.strikeout: !!row.task.done
                    color: row.task.done ? Theme.surfaceTextSecondary : Theme.surfaceText
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
                StyledText {
                    // A subtask shown apart from its parent names it
                    visible: row.task.parentTitle !== ""
                    text: "↳ " + row.task.parentTitle
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceTextSecondary
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                RowLayout {
                    visible: (!!row.task.due && !row.task.done) || row.subtaskCount > 0 || row.listCaption !== ""
                    spacing: Theme.spacingXS
                // due date chip
                Rectangle {
                    visible: !!row.task.due && !row.task.done
                    implicitHeight: dueRow.implicitHeight + 4
                    implicitWidth: dueRow.implicitWidth + Theme.spacingS * 2
                    radius: height / 2
                    color: "transparent"
                    border.width: 1
                    border.color: row.due === "overdue" ? Theme.withAlpha(Theme.error, 0.6) : row.due === "today" ? Theme.withAlpha(Theme.primary, 0.7) : Theme.withAlpha(Theme.surfaceText, 0.25)
                    RowLayout {
                        id: dueRow
                        anchors.centerIn: parent
                        spacing: 4
                        DIcon { name: "schedule"; size: Theme.fontSizeSmall + 2; color: row.due === "overdue" ? Theme.error : row.due === "today" ? Theme.primary : Theme.surfaceTextSecondary }
                        StyledText {
                            text: row.task.due ? root.dueLabel(row.task.due) : ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: row.due === "overdue" ? Theme.error : row.due === "today" ? Theme.primary : Theme.surfaceTextSecondary
                        }
                    }
                }
                // "▸ 3 subtasks": shows or hides them; marked when one of them is due
                Rectangle {
                    visible: row.subtaskCount > 0
                    implicitHeight: subRow.implicitHeight + 4
                    implicitWidth: subRow.implicitWidth + Theme.spacingS * 2
                    radius: height / 2
                    color: subMouse.containsMouse ? Theme.withAlpha(Theme.primary, 0.16) : row.expanded ? Theme.withAlpha(Theme.primary, 0.1) : "transparent"
                    border.width: 1
                    border.color: row.subtasksDue > 0 && !row.expanded ? Theme.withAlpha(Theme.error, 0.6) : Theme.withAlpha(Theme.surfaceText, 0.25)
                    RowLayout {
                        id: subRow
                        anchors.centerIn: parent
                        spacing: 2
                        DIcon { name: row.expanded ? "expand_less" : "expand_more"; size: Theme.fontSizeSmall + 4; color: Theme.surfaceTextSecondary }
                        StyledText {
                            text: root.plural(row.subtaskCount, I18n.trFor("dcalAgenda", "%1 subtask|%1 subtasks"))
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceTextSecondary
                        }
                    }
                    MouseArea {
                        id: subMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: row.toggleSubtasks()
                    }
                }
                // which list, when several are shown
                StyledText {
                    visible: row.listCaption !== ""
                    text: row.listCaption
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceTextSecondary
                    elide: Text.ElideRight
                    Layout.maximumWidth: 160
                }
                }
            }
        }
    }

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
            DIcon { name: hb.icon; size: Theme.iconSize - 4; color: Theme.primary }
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

    Rectangle {
        anchors.fill: parent
        radius: Theme.cornerRadius
        color: root.bgColor

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
                    DIcon { name: "calendar_month"; size: Theme.iconSize; color: Theme.primary }
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
            // Same layout as the calendar: header with sync and a "+ Task" button,
            // list chips to show or hide lists, then the tasks of every shown list
            // by day
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                spacing: Theme.spacingS

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingS
                    DIcon { name: "task_alt"; size: Theme.iconSize; color: Theme.primary }
                    StyledText { text: I18n.trFor("dcalAgenda", "Tasks"); font.pixelSize: Theme.fontSizeLarge; font.weight: Font.Medium; color: Theme.surfaceText }
                    StyledText {
                        visible: root.openGroups.length > 0
                        text: root.openGroups.length
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceTextSecondary
                    }
                    Item { Layout.fillWidth: true }
                    SyncButton {}
                    HeaderButton {
                        icon: "add"
                        label: I18n.trFor("dcalAgenda", "Task")
                        enabled: root.taskLists.length > 0
                        onClicked: root.openEditor("")
                    }
                }

                // Task list filter: click to hide or show
                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.spacingXS
                    visible: root.taskLists.length > 1

                    Repeater {
                        model: root.taskLists
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool shown: root.hiddenTaskLists.indexOf(modelData.id) < 0
                            height: listChipRow.implicitHeight + Theme.spacingXS * 2
                            width: listChipRow.implicitWidth + Theme.spacingS * 2
                            radius: height / 2
                            color: shown ? Theme.withAlpha(modelData.color || Theme.primary, 0.18) : "transparent"
                            border.width: 1
                            border.color: Theme.withAlpha(modelData.color || Theme.primary, shown ? 0.5 : 0.25)

                            RowLayout {
                                id: listChipRow
                                anchors.centerIn: parent
                                spacing: Theme.spacingXS
                                Rectangle { width: 8; height: 8; radius: 4; color: modelData.color || Theme.primary; opacity: parent.parent.shown ? 1 : 0.4 }
                                StyledText {
                                    text: root.listName(modelData)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: parent.parent.shown ? Theme.surfaceText : Theme.surfaceTextSecondary
                                    font.strikeout: !parent.parent.shown
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleTaskList(modelData.id)
                            }
                        }
                    }
                }

                TaskEditor {
                    visible: root.editorAt === "new"
                    Layout.fillWidth: true
                }

                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentHeight: tasksCol.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: tasksCol
                        width: parent.width
                        spacing: Theme.spacingM

                        StyledText {
                            visible: root.taskLists.length === 0 || (root.taskDays.length === 0 && root.doneList.length === 0)
                            text: root.errorText || (root.taskLists.length === 0 ? I18n.trFor("dcalAgenda", "No task lists") : I18n.trFor("dcalAgenda", "All tasks complete 🎉"))
                            color: Theme.surfaceTextSecondary
                            font.pixelSize: Theme.fontSizeMedium
                        }

                        Repeater {
                            model: root.taskDays

                            delegate: ColumnLayout {
                                id: day
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: Theme.spacingXS

                                StyledText {
                                    text: day.modelData.label
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: day.modelData.kind === "overdue" ? Theme.error : Theme.primary
                                }

                                // One card per task with its subtasks, so a group reads as a
                                // unit; the stripe shows its most urgent due date, and the card
                                // outlines while the pointer is in it
                                Repeater {
                                    model: day.modelData.groups
                                    delegate: Rectangle {
                                        id: group
                                        required property var modelData
                                        readonly property string state_: root.groupState(modelData)
                                        readonly property bool expanded: root.expandedTasks.indexOf(modelData.task.uid) >= 0
                                        readonly property bool addingSubtask: root.editorAt !== "" && root.editorAt === modelData.task.uid
                                        Layout.fillWidth: true
                                        implicitHeight: groupCol.implicitHeight + 4
                                        radius: Theme.cornerRadius / 1.5
                                        color: root.tileBg
                                        border.width: 1
                                        border.color: groupHover.hovered || addingSubtask ? Theme.withAlpha(Theme.primary, 0.4) : "transparent"
                                        Behavior on border.color { ColorAnimation { duration: 150 } }

                                        HoverHandler { id: groupHover }

                                        // urgency stripe
                                        Rectangle {
                                            visible: group.state_ !== ""
                                            anchors.left: parent.left
                                            anchors.top: parent.top
                                            anchors.bottom: parent.bottom
                                            anchors.margins: Theme.spacingXS
                                            width: 3
                                            radius: 1.5
                                            color: group.state_ === "overdue" ? Theme.error : Theme.primary
                                        }

                                        ColumnLayout {
                                            id: groupCol
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            anchors.margins: 2
                                            anchors.leftMargin: Theme.spacingXS + 5
                                            spacing: 0

                                            TaskRow {
                                                Layout.fillWidth: true
                                                task: group.modelData.task
                                                subtaskCount: group.modelData.children.length
                                                subtasksDue: group.modelData.children.filter(c => root.dueState(c) === "overdue").length
                                                expanded: group.expanded
                                                listCaption: root.visibleTaskLists.length > 1 ? root.listOf(group.modelData.task) : ""
                                                onToggleSubtasks: root.toggleSubtasks(group.modelData.task.uid)
                                            }

                                            // Subtasks, indented under the parent with a guide line,
                                            // completed ones included; then "+ Subtask"
                                            Item {
                                                visible: group.expanded && !!group.modelData.task.uid
                                                Layout.fillWidth: true
                                                implicitHeight: subCol.implicitHeight

                                                Rectangle {
                                                    x: Theme.spacingS + (Theme.iconSize - 2) / 2
                                                    y: 0
                                                    width: 1
                                                    height: parent.height - Theme.spacingS
                                                    color: Theme.withAlpha(Theme.surfaceText, 0.18)
                                                }

                                                ColumnLayout {
                                                    id: subCol
                                                    anchors.left: parent.left
                                                    anchors.right: parent.right
                                                    anchors.leftMargin: Theme.iconSize + Theme.spacingS
                                                    spacing: 0
                                                    Repeater {
                                                        model: group.modelData.children
                                                        delegate: TaskRow {
                                                            required property var modelData
                                                            Layout.fillWidth: true
                                                            task: modelData
                                                        }
                                                    }

                                                    TaskEditor {
                                                        visible: group.addingSubtask
                                                        Layout.fillWidth: true
                                                        Layout.topMargin: Theme.spacingXS
                                                        Layout.bottomMargin: Theme.spacingS
                                                    }

                                                    // "+ Subtask"
                                                    Rectangle {
                                                        visible: !group.addingSubtask
                                                        Layout.fillWidth: true
                                                        implicitHeight: addSubRow.implicitHeight + Theme.spacingS * 2
                                                        radius: Theme.cornerRadius / 2
                                                        color: addSubMouse.containsMouse ? Theme.withAlpha(Theme.primary, 0.10) : "transparent"
                                                        RowLayout {
                                                            id: addSubRow
                                                            anchors.fill: parent
                                                            anchors.margins: Theme.spacingS
                                                            spacing: Theme.spacingS
                                                            DIcon { name: "add"; size: Theme.iconSize - 4; color: Theme.primary }
                                                            StyledText {
                                                                text: I18n.trFor("dcalAgenda", "Subtask")
                                                                font.pixelSize: Theme.fontSizeSmall
                                                                font.weight: Font.Medium
                                                                color: Theme.primary
                                                                Layout.fillWidth: true
                                                            }
                                                        }
                                                        MouseArea {
                                                            id: addSubMouse
                                                            anchors.fill: parent
                                                            hoverEnabled: true
                                                            cursorShape: Qt.PointingHandCursor
                                                            onClicked: root.openSubtaskEditor(group.modelData.task)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Completed tasks in a collapsed block
                        Item {
                            visible: root.doneList.length > 0
                            Layout.fillWidth: true
                            Layout.topMargin: Theme.spacingS
                            implicitHeight: doneHeader.implicitHeight
                            RowLayout {
                                id: doneHeader
                                anchors.left: parent.left
                                anchors.right: parent.right
                                spacing: Theme.spacingS
                                DIcon {
                                    name: root.doneExpanded ? "expand_more" : "chevron_right"
                                    size: Theme.iconSize - 2
                                    color: Theme.surfaceTextSecondary
                                }
                                StyledText {
                                    text: root.plural(root.doneList.length, I18n.trFor("dcalAgenda", "%1 task completed|%1 tasks completed"))
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceTextSecondary
                                    Layout.fillWidth: true
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.doneExpanded = !root.doneExpanded
                            }
                        }

                        Repeater {
                            model: root.doneExpanded ? root.doneList : []
                            delegate: TaskRow {
                                required property var modelData
                                Layout.fillWidth: true
                                task: modelData
                                listCaption: modelData.completedAt ? I18n.trFor("dcalAgenda", "Completed %1").arg(I18n.locale().toString(modelData.completedAt, I18n.trFor("dcalAgenda", "ddd, MMM d"))) : ""
                            }
                        }
                    }
                }
            }
        }
    }
}
