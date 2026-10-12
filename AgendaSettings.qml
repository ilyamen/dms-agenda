import QtQuick
import qs.Common
import qs.Modules.Plugins

// Календари для показа выбираются чипами прямо на виджете
PluginSettings {
    id: root

    pluginId: "dcalAgenda"

    SliderSetting {
        settingKey: "daysAhead"
        label: "Дней вперёд"
        description: "Сколько дней показывать в календаре. Дни без событий пропускаются."
        defaultValue: 14
        minimum: 1
        maximum: 60
    }

    SliderSetting {
        settingKey: "refreshMinutes"
        label: "Обновлять каждые"
        description: "Как часто перечитывать события и задачи из dcal. Синхронизацию с Google dcal делает сам, кнопка синхронизации на виджете запускает её сразу."
        defaultValue: 5
        minimum: 1
        maximum: 60
        unit: " мин"
    }

    SliderSetting {
        settingKey: "backgroundOpacity"
        label: "Непрозрачность фона"
        defaultValue: 80
        minimum: 0
        maximum: 100
        unit: "%"
    }
}
