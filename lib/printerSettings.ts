export type ReceiptPrintFormat="standard"|"58mm";
export type PrinterConnectionMode="system"|"web_bluetooth";
export type PrinterSettings={defaultFormat:ReceiptPrintFormat;connectionMode:PrinterConnectionMode;deviceId:string|null;deviceName:string|null};

const STORAGE_KEY="labaflow.printer.settings.v1";
const defaults:PrinterSettings={defaultFormat:"58mm",connectionMode:"system",deviceId:null,deviceName:null};

export function loadPrinterSettings():PrinterSettings{
 if(typeof window==="undefined")return defaults;
 try{return {...defaults,...JSON.parse(localStorage.getItem(STORAGE_KEY)||"{}")}}catch{return defaults}
}
export function savePrinterSettings(settings:PrinterSettings){localStorage.setItem(STORAGE_KEY,JSON.stringify(settings));window.dispatchEvent(new CustomEvent("labaflow:printer-settings",{detail:settings}))}
export function supportsWebBluetooth(){return typeof navigator!=="undefined"&&Boolean((navigator as any).bluetooth?.requestDevice)}
export async function chooseBluetoothPrinter(){
 const bluetooth=(navigator as any).bluetooth;if(!bluetooth?.requestDevice)throw new Error("Bluetooth printer discovery is not supported by this browser.");
 const device=await bluetooth.requestDevice({acceptAllDevices:true});let connected=false;
 if(device.gatt){try{await device.gatt.connect();connected=Boolean(device.gatt.connected)}catch{connected=false}}
 return {id:String(device.id||""),name:String(device.name||"Bluetooth printer"),connected};
}
