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
        settingKey: "backgroundOpacity"
        label: I18n.trFor("dcalAgenda", "Background opacity")
        defaultValue: 80
        minimum: 0
        maximum: 100
        unit: "%"
    }
}
