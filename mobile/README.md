# LabaFlow Android pilot

This Capacitor shell loads the staging LabaFlow application and supplies native Bluetooth Low Energy access for direct ESC/POS receipt printing.

## Local setup

1. Install Android Studio and its Android SDK.
2. From this directory run `npm install`.
3. Run `npm run android:add` once, then `npm run android:sync` after plugin changes.
4. Run `npm run android:open` and build/install the debug app on a physical Android device.

The default app URL is staging. To prepare a production build, set `LABAFLOW_APP_URL=https://labaflow.paotechs.com` before running `npm run android:sync`.

The Bluetooth plugin supports BLE printers only. Bluetooth Classic/serial printers require a different native plugin.
