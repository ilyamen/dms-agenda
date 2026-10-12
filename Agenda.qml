import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

// Календарь и задачи из DankCalendar (dcal) на рабочем столе.
// Слева — события по дням с фильтром календарей, справа — списки задач в стиле Google Tasks.
// Все данные и изменения идут через `dcal ipc ...` (dcal сам синхронизирует с Google).
DesktopPluginComponent {
    id: root

    minWidth: 420
    minHeight: 240

    property int daysAhead: pluginData.daysAhead ?? 14
    property int refreshMinutes: pluginData.refreshMinutes ?? 5
    property real backgroundOpacity: (pluginData.backgroundOpacity ?? 80) / 100

    property var calendars: []        // все календари и списки задач из dcal
    property var events: []
    property var tasks: []
    property var hiddenCalendars: pluginData.hiddenCalendars ?? []
    property var expandedDone: ({})   // calendarId -> развернут ли блок выполненных
    property string errorText: ""

    // Поле «Добавить задачу»: пока оно открыто, виджет принимает клавиатуру
    property string addingToList: ""
    property bool acceptsKeyboardFocus: addingToList !== ""

    readonly property color bgColor: Theme.withAlpha(Theme.surface, backgroundOpacity)
    readonly property color tileBg: Theme.withAlpha(Theme.surfaceContainerHigh, backgroundOpacity)

    // у Google-календарей supportedComponents пустой — это календари событий; списки задач помечены holdsTasks
    readonly property var eventCalendars: calendars.filter(c => !c.supportedComponents || c.supportedComponents.indexOf("VEVENT") >= 0)
    readonly property var taskLists: calendars.filter(c => c.holdsTasks && (c.supportedComponents || []).indexOf("VTODO") >= 0)

    // ---------- даты ----------

    function pad(n) { return n < 10 ? "0" + n : "" + n; }

    function rfc3339(d) {
        const off = -d.getTimezoneOffset();
        const sign = off >= 0 ? "+" : "-";
        return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
            + "T" + pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds())
            + sign + pad(Math.floor(Math.abs(off) / 60)) + ":" + pad(Math.abs(off) % 60);
    }

    // Для событий «на весь день» и сроков задач Google отдаёт полночь UTC — берём только дату
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

    function plural(n, one, few, many) {
        const m10 = n % 10, m100 = n % 100;
        if (m10 === 1 && m100 !== 11)
            return one;
        if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
            return few;
        return many;
    }

    function dayLabel(d) {
        const diff = daysFromToday(d);
        if (diff === 0)
            return "Сегодня";
        if (diff === 1)
            return "Завтра";
        const s = Qt.locale("ru_RU").toString(d, "dddd, d MMMM");
        return s.charAt(0).toUpperCase() + s.slice(1);
    }

    function timeLabel(e) {
        if (e.allDay)
            return "весь день";
        return Qt.formatTime(e.start, "HH:mm") + (e.end ? "–" + Qt.formatTime(e.end, "HH:mm") : "");
    }

    // «11 недель назад», «сегодня», «завтра», «пт, 17 окт.»
    function dueLabel(d) {
        const diff = daysFromToday(d);
        if (diff === 0)
            return "сегодня";
        if (diff === 1)
            return "завтра";
        if (diff === -1)
            return "вчера";
        if (diff < 0) {
            const n = -diff;
            if (n < 14)
                return n + " " + plural(n, "день", "дня", "дней") + " назад";
            if (n < 91) {
                const w = Math.floor(n / 7);
                return w + " " + plural(w, "неделю", "недели", "недель") + " назад";
            }
            const mo = Math.floor(n / 30);
            return mo + " " + plural(mo, "месяц", "месяца", "месяцев") + " назад";
        }
        return Qt.locale("ru_RU").toString(d, "ddd, d MMM");
    }

    // ---------- данные ----------

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
            root.errorText = "dcal не отвечает";
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
                    title: e.summary || "(без названия)",
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
                    title: t.summary || "(без названия)",
                    due: root.toDate(t.due, true),
                    done: t.status === "completed",
                    completedAt: root.toDate(t.completed, false),
                    calendarId: t.calendarId
                }));
            }
        }
    }

    // Изменения (создать / выполнить / вернуть) — по одному, затем обновляем
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
        // мгновенно в интерфейсе, не дожидаясь dcal
        root.tasks = root.tasks.map(t => t.id === task.id ? Object.assign({}, t, { done: done, completedAt: done ? new Date() : null }) : t);
        runCommand(["dcal", "ipc", "tasks.complete", "id=" + task.id, "completed=" + done]);
    }

    // Google Tasks хранит у задачи только дату (без времени) — шлём полночь UTC этого дня
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
        // сразу показываем в списке, dcal догонит при обновлении
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
        // «12.01» без года, если дата уже прошла, — значит следующий год
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

    // Редактор новой задачи: название, срок, описание, список
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

            // Название
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
                        text: "Добавьте название"
                        font.pixelSize: Theme.fontSizeLarge
                        color: Theme.surfaceTextSecondary
                    }
                }
                Rectangle { width: parent.width; height: 1; color: titleInput.activeFocus ? Theme.primary : Theme.outlineVariant }
            }

            // Срок
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingS
                DankIcon { name: "schedule"; size: Theme.iconSize - 4; color: Theme.surfaceTextSecondary; Layout.alignment: Qt.AlignTop; Layout.topMargin: 4 }
                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.spacingXS
                    Chip { label: "Без даты"; selected: ed.dueMode === "none"; onClicked: ed.setDue("none") }
                    Chip { label: "Сегодня"; selected: ed.dueMode === "today"; onClicked: ed.setDue("today") }
                    Chip { label: "Завтра"; selected: ed.dueMode === "tomorrow"; onClicked: ed.setDue("tomorrow") }
                    Chip { label: "Через неделю"; selected: ed.dueMode === "week"; onClicked: ed.setDue("week") }
                    // своя дата: дд.мм или дд.мм.гггг
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
                                text: "дд.мм"
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
                text: ed.due ? "Срок: " + Qt.locale("ru_RU").toString(ed.due, "dddd, d MMMM yyyy") : ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceTextSecondary
            }

            // Описание
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
                            text: "Добавьте описание"
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceTextSecondary
                        }
                    }
                }
            }

            // Список (если их несколько)
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

            // Кнопки
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingS
                Item { Layout.fillWidth: true }
                Chip { label: "Отмена"; onClicked: ed.close() }
                Rectangle {
                    implicitHeight: saveText.implicitHeight + Theme.spacingS * 2
                    implicitWidth: saveText.implicitWidth + Theme.spacingL * 2
                    radius: height / 2
                    readonly property bool ready: titleInput.text.trim() !== ""
                    color: ready ? Theme.primary : Theme.withAlpha(Theme.surfaceText, 0.12)
                    StyledText {
                        id: saveText
                        anchors.centerIn: parent
                        text: "Сохранить"
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
        return /'s list$/.test(c.name) ? "Мои задачи" : c.name;
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

    // ---------- синхронизация ----------
    // dcal сам синхронизирует аккаунт примерно раз в минуту; ошибки пишет в журнал systemd.
    // syncState: idle | syncing | ok | error

    property string syncState: "idle"
    property string syncError: ""
    property date lastOk

    function syncErrorText(line) {
        if (/retry deferred|rateLimit|quota/i.test(line))
            return "лимит Google";
        if (/auth|token|401|invalid_grant/i.test(line))
            return "нужен вход в Google";
        if (/dial|timeout|network|no such host/i.test(line))
            return "нет сети";
        return "ошибка синхр.";
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

    // Ручная синхронизация: запускаем, ждём, смотрим, не было ли ошибки за это время
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

    // Фоновая проверка: были ли ошибки синхронизации за последние 3 минуты
    Process {
        id: statusProc
        command: ["sh", "-c", "journalctl --user -u dcal --since -3min -o cat 2>/dev/null | grep 'sync error' | tail -n1"]
        stdout: StdioCollector {
            onStreamFinished: if (root.syncState !== "syncing") root.applySyncResult(text)
        }
    }

    // Иконка + статус синхронизации для заголовков
    component SyncButton: RowLayout {
        spacing: Theme.spacingXS
        StyledText {
            text: root.syncState === "syncing" ? "синхронизация…"
                : root.syncState === "error" ? root.syncError
                : root.syncState === "ok" ? "синхр. " + Qt.formatTime(root.lastOk, "HH:mm") : ""
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

    // события видимых календарей, сгруппированные по дням (пустые дни не показываем)
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
        // как в Google: сначала со сроком (раньше — выше), потом без срока
        list.sort((a, b) => (a.due ? a.due.getTime() : 8.64e15) - (b.due ? b.due.getTime() : 8.64e15));
        return list;
    }

    function doneTasks(listId) {
        const list = tasks.filter(t => t.calendarId === listId && t.done);
        list.sort((a, b) => (b.completedAt ? b.completedAt.getTime() : 0) - (a.completedAt ? a.completedAt.getTime() : 0));
        return list;
    }

    // ---------- общие элементы ----------

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

    // ---------- вид ----------

    Rectangle {
        anchors.fill: parent
        radius: Theme.cornerRadius
        color: root.bgColor

        RowLayout {
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingL

            // ===== Календарь =====
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                spacing: Theme.spacingS

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingS
                    DankIcon { name: "calendar_month"; size: Theme.iconSize; color: Theme.primary }
                    StyledText { text: "Календарь"; font.pixelSize: Theme.fontSizeLarge; font.weight: Font.Medium; color: Theme.surfaceText }
                    Item { Layout.fillWidth: true }
                    SyncButton {}
                    HeaderButton {
                        icon: "add"
                        label: "Событие"
                        onClicked: root.runCommand(["dcal", "ipc", "ui.newEvent"])
                    }
                }

                // Фильтр календарей: клик — скрыть / показать
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
                                    text: modelData.name.indexOf("@") > 0 ? "Мой" : modelData.name
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
                                required property var modelData
                                width: parent.width
                                height: evCol.implicitHeight + Theme.spacingS * 2
                                radius: Theme.cornerRadius / 2
                                color: evMouse.containsMouse ? Theme.withAlpha(Theme.primary, 0.12) : root.tileBg

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    anchors.margins: Theme.spacingS
                                    width: 4
                                    radius: 2
                                    color: root.calendarColor(modelData.calendarId)
                                }

                                ColumnLayout {
                                    id: evCol
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingS * 2 + 4
                                    anchors.rightMargin: Theme.spacingS
                                    spacing: 0

                                    StyledText {
                                        text: modelData.title
                                        font.pixelSize: Theme.fontSizeMedium
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
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
                        text: root.errorText || ("Событий на " + root.daysAhead + " " + root.plural(root.daysAhead, "день", "дня", "дней") + " нет")
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

            // ===== Задачи =====
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
                        text: root.errorText || "Списков задач нет"
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

                            // Название списка
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

                            // Добавить задачу: строка-кнопка, по клику — редактор как в Google
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
                                        text: "Добавить задачу"
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

                            // Невыполненные (включая просроченные)
                            Repeater {
                                model: listBlock.open
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool overdue: !!modelData.due && root.daysFromToday(modelData.due) < 0
                                    Layout.fillWidth: true
                                    implicitHeight: taskRow.implicitHeight + Theme.spacingS * 2
                                    radius: Theme.cornerRadius / 2
                                    color: taskMouse.containsMouse ? Theme.withAlpha(Theme.primary, 0.08) : "transparent"

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
                                            // плашка срока
                                            Rectangle {
                                                visible: !!modelData.due
                                                implicitHeight: dueRow.implicitHeight + 4
                                                implicitWidth: dueRow.implicitWidth + Theme.spacingS * 2
                                                radius: height / 2
                                                color: "transparent"
                                                border.width: 1
                                                border.color: overdue ? Theme.withAlpha(Theme.error, 0.6) : Theme.withAlpha(Theme.surfaceText, 0.25)
                                                RowLayout {
                                                    id: dueRow
                                                    anchors.centerIn: parent
                                                    spacing: 4
                                                    DankIcon { name: "schedule"; size: Theme.fontSizeSmall + 2; color: overdue ? Theme.error : Theme.surfaceTextSecondary }
                                                    StyledText {
                                                        text: modelData.due ? root.dueLabel(modelData.due) : ""
                                                        font.pixelSize: Theme.fontSizeSmall
                                                        color: overdue ? Theme.error : Theme.surfaceTextSecondary
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
                                text: "Все задачи выполнены 🎉"
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceTextSecondary
                                Layout.leftMargin: Theme.spacingS
                            }

                            // Выполненные — свёрнутым блоком
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
                                        text: n + " " + root.plural(n, "задача выполнена", "задачи выполнено", "задач выполнено")
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
                                            text: modelData.completedAt ? "Выполнена: " + Qt.locale("ru_RU").toString(modelData.completedAt, "ddd, d MMM") : ""
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
