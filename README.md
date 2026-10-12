# Agenda for DankMaterialShell

A [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) desktop widget with your calendar and tasks from [DankCalendar](https://github.com/AvengeMedia/dankcalendar) (`dcal`), which syncs them with Google Calendar and Google Tasks.

- **Events** for the next days, grouped by day; days without events are skipped. Chips at the top hide or show each calendar, and a click on an event opens it in dcal. **Event** creates a new one.
- **Tasks** in the style of Google Tasks, one block per task list: open tasks sorted by due date with overdue ones in red, **Add task** with a due date, description and list, and a collapsed block of completed tasks. A click completes a task or brings it back.
- **Sync** buttons make dcal sync with Google right away and show whether it worked (rate limit, sign-in needed, offline).

The interface is in English and Russian.

## Requirements

- DMS 1.6.0 or newer
- DankCalendar with an account set up: `dcal account setup google`

Google's shared OAuth client of dcal often hits its quota. If syncing keeps failing with a rate limit, create your own OAuth client in Google Cloud and pass it to `dcal account setup google --credentials client_secret.json`.

## Installation

In DMS Settings → Plugins, add the registry `https://github.com/ilyamen/dms-plugin-registry.git` and install **Agenda** from Browse, or:

```sh
git clone https://github.com/ilyamen/dms-agenda ~/.config/DankMaterialShell/plugins/dcalAgenda
```

Enable it in Settings → Plugins and add the widget in Settings → Desktop Widgets. The widget's settings are on its card there.

## Removal

Uninstall the plugin in Settings → Plugins. It keeps nothing outside its folder.

## Settings

| Setting | Default | |
| --- | --- | --- |
| Days ahead | 14 | |
| Refresh every | 5 min | How often the widget re-reads dcal; dcal syncs with Google on its own |
| Background opacity | 80% | |

## License

MIT
