import QtQuick
import qs.Common
import qs.Modules.Plugins

// Calendars to show are picked with the chips on the widget itself
PluginSettings {
    id: root

    pluginId: "dcalAgenda"

    SliderSetting {
        settingKey: "daysAhead"
        label: I18n.trFor("dcalAgenda", "Days ahead")
        description: I18n.trFor("dcalAgenda", "How many days of events to show. Days without events are skipped.")
        defaultValue: 14
        minimum: 1
        maximum: 60
    }

    SliderSetting {
        settingKey: "refreshMinutes"
        label: I18n.trFor("dcalAgenda", "Refresh every")
        description: I18n.trFor("dcalAgenda", "How often to re-read events and tasks from dcal. dcal syncs with Google on its own; the sync button on the widget does it right away.")
        defaultValue: 5
        minimum: 1
        maximum: 60
        unit: I18n.trFor("dcalAgenda", " min")
    }

    SliderSetting {
        settingKey: "soonMinutes"
        label: I18n.trFor("dcalAgenda", "Highlight events before they start")
        description: I18n.trFor("dcalAgenda", "An event is highlighted this many minutes before it starts and while it runs.")
        defaultValue: 5
        minimum: 0
        maximum: 30
        unit: I18n.trFor("dcalAgenda", " min")
    }

    ToggleSetting {
        settingKey: "pulseCurrent"
        label: I18n.trFor("dcalAgenda", "Draw attention to the current event")
        description: I18n.trFor("dcalAgenda", "A few slow, soft glows when an event is about to start and when it starts, repeated every 10 minutes while it runs. Off when DMS reduces motion.")
        defaultValue: true
    }

    SliderSetting {
        settingKey: "backgroundOpacity"
        label: I18n.trFor("dcalAgenda", "Background opacity")
        defaultValue: 80
        minimum: 0
        maximum: 100
        unit: "%"
    }
}
