# MacBook automatic brightness for Omarchy

Automatic display brightness for Intel MacBooks running Omarchy. The plugin is
self-contained and uses only the stock kernel's `acpi-als` IIO sensor together
with Omarchy's standard `brightnessctl` command.

It does not install a systemd service, copy executables outside its checkout,
modify kernel drivers, or require administrator privileges. Omarchy owns the
complete lifecycle: enabling the plugin starts its singleton backend service;
disabling or removing it stops the backend.

## Requirements

- An IIO ambient light sensor. The MacBook's `acpi-als` (`in_illuminance_input`)
  is preferred; any other IIO light sensor is used as a fallback, including ones
  that expose only `in_illuminance_raw` with an `in_illuminance_scale` (e.g. the
  Intel sensor hub `als` found on many non-Apple laptops).
- `brightnessctl`, included with Omarchy.

## Install

Use Omarchy's plugin manager:

```sh
omarchy plugin add https://github.com/huangzuo/macbook-auto-brightness-plugin.git --enable
```

No separate setup step is required. The plugin starts tracking ambient light
as soon as Omarchy enables it.

## Controls

The bar widget displays measured lux, current brightness, and target
brightness. Its panel can:

- pause or enable automatic control;
- resume after a manual brightness override;
- select Dim, Balanced, or Bright preferences;
- tune response speed and smoothing.

Preferences are stored as settings on the widget's entry in
`~/.config/omarchy/shell.json`. They are removed together with that entry when
the plugin is removed.

## Remove

One command removes the UI, stops the singleton backend process, deletes its
checkout, and clears its inline settings:

```sh
omarchy plugin remove hz.auto-brightness
```

## Architecture

```text
Panel.qml                bar widget and controls
Service.qml              singleton Quickshell service and settings owner
bin/auto-brightness      child process for sensor sampling and brightness logic
manifest.json            Omarchy plugin metadata and entry points
```

`Service.qml` owns the child process. Omarchy destroys the service when the
plugin is disabled or removed, which terminates the child automatically. The
backend reads JSON status lines from the child and shares live state with every
bar instance, avoiding duplicate controllers on multi-monitor configurations.

## Validate

```sh
omarchy plugin validate .
/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" Panel.qml Service.qml
bash -n bin/auto-brightness
```

The plugin uses the permanent third-party ID `hz.auto-brightness`; keep the
directory name, manifest ID, QML `moduleName`, and service lookup aligned if it
is ever renamed.

The project is licensed under GPL-2.0-only.
