export type ReceiptPrintFormat="standard"|"58mm";
export type PrinterConnectionMode="system"|"web_bluetooth";
export type PrinterSettings={defaultFormat:ReceiptPrintFormat;connectionMode:PrinterConnectionMode;deviceId:string|null;deviceName:string|null};

const STORAGE_KEY="labaflow.printer.settings.v1";
const defaults:PrinterSettings={defaultFormat:"58mm",connectionMode:"system",deviceId:null,deviceName:null};
const printerServices=["0000ffe0-0000-1000-8000-00805f9b34fb","000018f0-0000-1000-8000-00805f9b34fb","49535343-fe7d-4ae5-8fa9-9fafd205e455","6e400001-b5a3-f393-e0a9-e50e24dcca9e"];
let activeDevice:any=null;

export function loadPrinterSettings():PrinterSettings{
 if(typeof window==="undefined")return defaults;
 try{return {...defaults,...JSON.parse(localStorage.getItem(STORAGE_KEY)||"{}")}}catch{return defaults}
}
export function savePrinterSettings(settings:PrinterSettings){localStorage.setItem(STORAGE_KEY,JSON.stringify(settings));window.dispatchEvent(new CustomEvent("labaflow:printer-settings",{detail:settings}))}
export function supportsWebBluetooth(){return typeof navigator!=="undefined"&&Boolean((navigator as any).bluetooth?.requestDevice)}
export async function chooseBluetoothPrinter(){
 const bluetooth=(navigator as any).bluetooth;if(!bluetooth?.requestDevice)throw new Error("Bluetooth printer discovery is not supported by this browser.");
 const device=await bluetooth.requestDevice({acceptAllDevices:true,optionalServices:printerServices});activeDevice=device;let connected=false;
 if(device.gatt){try{await device.gatt.connect();connected=Boolean(device.gatt.connected)}catch{connected=false}}
 return {id:String(device.id||""),name:String(device.name||"Bluetooth printer"),connected};
}

async function resolvePrinter(){
 const saved=loadPrinterSettings();if(activeDevice?.id===saved.deviceId)return activeDevice;
 const bluetooth=(navigator as any).bluetooth;if(bluetooth?.getDevices&&saved.deviceId){const devices=await bluetooth.getDevices();activeDevice=devices.find((d:any)=>d.id===saved.deviceId)||null}
 if(!activeDevice)throw new Error("Reconnect the Bluetooth printer, then try printing again.");return activeDevice;
}

async function writableCharacteristic(device:any){
 if(!device.gatt)throw new Error("This Bluetooth device does not provide a printable data connection.");
 const server=device.gatt.connected?device.gatt:await device.gatt.connect(),services=await server.getPrimaryServices();
 for(const service of services){try{const characteristics=await service.getCharacteristics(),writable=characteristics.find((c:any)=>c.properties?.writeWithoutResponse||c.properties?.write);if(writable)return writable}catch{}}
 throw new Error("The printer connected, but no supported ESC/POS write channel was found. Use PrinterApp / System Print for this model.");
}

function receiptBytes(lines:string[]){
 const encoder=new TextEncoder(),parts:Uint8Array[]=[new Uint8Array([0x1b,0x40,0x1b,0x61,0x01]),encoder.encode("LabaFlow\nBluetooth Printer Test\n58 mm Thermal\n--------------------------------\n"),new Uint8Array([0x1b,0x61,0x00])];
 for(const line of lines)parts.push(encoder.encode(`${line}\n`));
 parts.push(encoder.encode("--------------------------------\n"),new Uint8Array([0x1b,0x61,0x01]),encoder.encode("Printer setup is ready\n\n\n"),new Uint8Array([0x1d,0x56,0x00]));
 const size=parts.reduce((n,p)=>n+p.length,0),result=new Uint8Array(size);let offset=0;for(const part of parts){result.set(part,offset);offset+=part.length}return result;
}

export async function printBluetoothTest(){
 const device=await resolvePrinter(),characteristic=await writableCharacteristic(device),bytes=receiptBytes([`Date: ${new Date().toLocaleString()}`,"Connection: Direct Bluetooth","Format: 58 mm ESC/POS"]);
 for(let offset=0;offset<bytes.length;offset+=100){const chunk=bytes.slice(offset,offset+100);if(characteristic.properties?.writeWithoutResponse&&characteristic.writeValueWithoutResponse)await characteristic.writeValueWithoutResponse(chunk);else await characteristic.writeValue(chunk)}
 return String(device.name||"Bluetooth printer");
}
