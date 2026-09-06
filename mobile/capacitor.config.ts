import type {CapacitorConfig} from "@capacitor/cli";

const appUrl=process.env.LABAFLOW_APP_URL||"https://staging.labaflow.paotechs.com";
const isProduction=appUrl==="https://labaflow.paotechs.com";

const config:CapacitorConfig={
 appId:isProduction?"com.paotechs.labaflow":"com.paotechs.labaflow.staging",
 appName:isProduction?"LabaFlow":"LabaFlow Staging",
 webDir:"www",
 server:{
  url:appUrl,
  cleartext:false,
  allowNavigation:["staging.labaflow.paotechs.com","labaflow.paotechs.com"]
 },
 android:{
  allowMixedContent:false,
  backgroundColor:"#f4fbfe"
 },
 plugins:{
  BluetoothLe:{
   displayStrings:{
    scanning:"Looking for receipt printers…",
    cancel:"Cancel",
    availableDevices:"Available Bluetooth printers",
    noDeviceFound:"No Bluetooth printer found"
   }
  }
 }
};

export default config;
