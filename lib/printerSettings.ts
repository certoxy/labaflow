export type ReceiptPrintFormat="standard"|"58mm";
export type PrinterConnectionMode="system"|"web_bluetooth";
export type PrinterSettings={defaultFormat:ReceiptPrintFormat;connectionMode:PrinterConnectionMode;deviceId:string|null;deviceName:string|null};
export type BluetoothReceiptLine={name:string;quantity:number|string;unitPrice:number;lineTotal:number};
export type BluetoothReceiptPayment={createdAt:string;method:string;amount:number;reference?:string|null};
export type BluetoothReceipt={business:string;branch?:string;address?:string;phone?:string;orderCode:string;createdAt:string;customer:string;customerCode?:string;status:string;paymentStatus:string;items:BluetoothReceiptLine[];products?:BluetoothReceiptLine[];subtotal:number;discount:number;total:number;amountPaid:number;balance:number;payments:BluetoothReceiptPayment[];notes?:string|null;footer?:string};

const STORAGE_KEY="labaflow.printer.settings.v1";
const defaults:PrinterSettings={defaultFormat:"58mm",connectionMode:"system",deviceId:null,deviceName:null};
const printerServices=["0000ffe0-0000-1000-8000-00805f9b34fb","000018f0-0000-1000-8000-00805f9b34fb","49535343-fe7d-4ae5-8fa9-9fafd205e455","6e400001-b5a3-f393-e0a9-e50e24dcca9e"];
let activeDevice:any=null;
let activePrint:Promise<string>|null=null;
const nativeBle=()=>typeof window!=="undefined"?(window as any).Capacitor?.Plugins?.BluetoothLe:null;
export const isNativeAndroidApp=()=>typeof window!=="undefined"&&Boolean((window as any).Capacitor?.isNativePlatform?.()||nativeBle());

export function loadPrinterSettings():PrinterSettings{
 if(typeof window==="undefined")return defaults;
 try{return {...defaults,...JSON.parse(localStorage.getItem(STORAGE_KEY)||"{}")}}catch{return defaults}
}
export function savePrinterSettings(settings:PrinterSettings){localStorage.setItem(STORAGE_KEY,JSON.stringify(settings));window.dispatchEvent(new CustomEvent("labaflow:printer-settings",{detail:settings}))}
export function supportsWebBluetooth(){return Boolean(nativeBle())||(typeof navigator!=="undefined"&&Boolean((navigator as any).bluetooth?.requestDevice))}
async function initializeNativeBle(){const plugin=nativeBle();if(!plugin)throw new Error("Native Bluetooth is unavailable.");await plugin.initialize();return plugin}
async function connectNative(plugin:any,deviceId:string){try{await plugin.connect({deviceId})}catch{try{await plugin.disconnect({deviceId})}catch{}await plugin.connect({deviceId})}}
async function requestNativePrinter(){const plugin=await initializeNativeBle(),device=await plugin.requestDevice({optionalServices:printerServices});activeDevice={id:String(device.deviceId||""),name:String(device.name||"Bluetooth printer"),native:true};await connectNative(plugin,activeDevice.id);return activeDevice}
async function requestBluetoothPrinter(){
 const bluetooth=(navigator as any).bluetooth;if(!bluetooth?.requestDevice)throw new Error("Bluetooth printer discovery is not supported by this browser.");
 const device=await bluetooth.requestDevice({acceptAllDevices:true,optionalServices:printerServices});activeDevice=device;return device;
}
export async function chooseBluetoothPrinter(){
 if(nativeBle()){const device=await requestNativePrinter();return {id:device.id,name:device.name,connected:true}}
 const device=await requestBluetoothPrinter();let connected=false;
 if(device.gatt){try{await device.gatt.connect();connected=Boolean(device.gatt.connected)}catch{connected=false}}
 return {id:String(device.id||""),name:String(device.name||"Bluetooth printer"),connected};
}

async function resolvePrinter(){
 const saved=loadPrinterSettings();if(activeDevice?.id===saved.deviceId)return activeDevice;
 if(activeDevice&&activeDevice.id!==saved.deviceId)activeDevice=null;
 if(nativeBle()&&saved.deviceId){const plugin=await initializeNativeBle();await connectNative(plugin,saved.deviceId);activeDevice={id:saved.deviceId,name:saved.deviceName||"Bluetooth printer",native:true};return activeDevice}
 if(!activeDevice){
  try{const device=nativeBle()?await requestNativePrinter():await requestBluetoothPrinter();savePrinterSettings({...saved,deviceId:String(device.id||""),deviceName:String(device.name||"Bluetooth printer")})}
  catch(error:any){if(error?.name==="NotFoundError")throw new Error("No printer was selected. Tap Print 58mm and select the Bluetooth printer to continue.");throw error}
 }
 return activeDevice;
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

const receiptWidth=32;
const plain=(value:unknown)=>String(value??"").normalize("NFKD").replace(/[\u0300-\u036f]/g,"").replace(/[^\x20-\x7e]/g,"?").replace(/\s+/g," ").trim();
const center=(value:unknown)=>{const text=plain(value).slice(0,receiptWidth);return " ".repeat(Math.max(0,Math.floor((receiptWidth-text.length)/2)))+text};
const money=(value:number)=>`PHP ${Number(value||0).toLocaleString("en-PH",{minimumFractionDigits:2,maximumFractionDigits:2})}`;
const pair=(left:unknown,right:unknown)=>{const r=plain(right).slice(0,receiptWidth),available=Math.max(1,receiptWidth-r.length-1),l=plain(left).slice(0,available);return `${l}${" ".repeat(Math.max(1,receiptWidth-l.length-r.length))}${r}`.slice(0,receiptWidth)};
function wrapped(value:unknown,width=receiptWidth){const words=plain(value).split(" ").filter(Boolean),lines:string[]=[];let line="";for(const word of words){if(word.length>width){if(line){lines.push(line);line=""}for(let i=0;i<word.length;i+=width)lines.push(word.slice(i,i+width));continue}const next=line?`${line} ${word}`:word;if(next.length>width){if(line)lines.push(line);line=word}else line=next}if(line)lines.push(line);return lines.length?lines:[""]}
function lineItems(title:string,items:BluetoothReceiptLine[]){if(!items.length)return[];const lines=[title.toUpperCase()];for(const item of items){lines.push(...wrapped(item.name));lines.push(pair(`${plain(item.quantity)} x ${money(item.unitPrice)}`,money(item.lineTotal)))}return lines}
function actualReceiptBytes(receipt:BluetoothReceipt){
 const rule="-".repeat(receiptWidth),lines=[center(receipt.business)];
 if(receipt.branch&&plain(receipt.branch)!==plain(receipt.business))lines.push(center(receipt.branch));
 if(receipt.address)lines.push(...wrapped(receipt.address).map(center));if(receipt.phone)lines.push(center(receipt.phone));
 lines.push(center("Laundry Service Receipt"),rule,pair("Order",receipt.orderCode),pair("Date",new Date(receipt.createdAt).toLocaleString()),pair("Customer",receipt.customer));
 if(receipt.customerCode)lines.push(pair("Customer Code",receipt.customerCode));
 lines.push(pair("Status",receipt.status),pair("Payment",receipt.paymentStatus),rule,...lineItems("Services",receipt.items));
 if(receipt.products?.length)lines.push(rule,...lineItems("Products",receipt.products));
 lines.push(rule,pair("Subtotal",money(receipt.subtotal)));
 if(receipt.discount>0)lines.push(pair("Discount",`-${money(receipt.discount)}`));
 lines.push(pair("TOTAL",money(receipt.total)),pair("Paid",money(receipt.amountPaid)),pair("Balance",money(receipt.balance)));
 if(receipt.notes)lines.push(rule,"NOTES",...wrapped(receipt.notes));
 lines.push(rule,"PAYMENTS");
 if(receipt.payments.length){for(const payment of receipt.payments){lines.push(pair(plain(payment.method),money(payment.amount)),...wrapped(new Date(payment.createdAt).toLocaleString()));if(payment.reference)lines.push(...wrapped(`Ref: ${payment.reference}`))}}else lines.push("No payment recorded yet.");
 lines.push(rule,...wrapped(receipt.footer||`Thank you for choosing ${receipt.business}.`).map(center),center("Powered by LabaFlow"),center("labaflow.paotechs.com"));
 const encoder=new TextEncoder(),parts=[new Uint8Array([0x1b,0x40,0x1b,0x61,0x00]),encoder.encode(lines.join("\n")+"\n\n\n"),new Uint8Array([0x1d,0x56,0x00])],size=parts.reduce((n,p)=>n+p.length,0),result=new Uint8Array(size);let offset=0;for(const part of parts){result.set(part,offset);offset+=part.length}return result;
}

const wait=(milliseconds:number)=>new Promise(resolve=>setTimeout(resolve,milliseconds));
async function withTimeout<T>(operation:Promise<T>,milliseconds=8000){let timer:ReturnType<typeof setTimeout>|undefined;try{return await Promise.race([operation,new Promise<T>((_,reject)=>{timer=setTimeout(()=>reject(new Error("The printer stopped responding. Reconnect it in Printer Settings, then try again.")),milliseconds)})])}finally{if(timer)clearTimeout(timer)}}
const hexadecimal=(bytes:Uint8Array)=>Array.from(bytes,byte=>byte.toString(16).padStart(2,"0")).join("");
async function sendToNativePrinter(bytes:Uint8Array){
 const plugin=await initializeNativeBle(),device=await resolvePrinter();let discovered:any;
 try{
  try{discovered=await plugin.getServices({deviceId:device.id})}catch{await connectNative(plugin,device.id);discovered=await plugin.getServices({deviceId:device.id})}
  const services=discovered?.services??discovered??[];let target:any=null;
  for(const service of services){const characteristic=(service.characteristics??[]).find((item:any)=>item.properties?.write||item.properties?.writeWithoutResponse);if(characteristic){target={service:service.uuid,characteristic:characteristic.uuid,withResponse:Boolean(characteristic.properties?.write)};break}}
  if(!target)throw new Error("The printer connected, but no supported ESC/POS write channel was found.");
  for(let offset=0;offset<bytes.length;offset+=20){const value=hexadecimal(bytes.slice(offset,offset+20)),options={deviceId:device.id,service:target.service,characteristic:target.characteristic,value};if(target.withResponse)await withTimeout(plugin.write(options));else await withTimeout(plugin.writeWithoutResponse(options));await wait(25)}
  return String(device.name||"Bluetooth printer");
 }finally{
  await wait(150);
  try{await plugin.disconnect({deviceId:device.id})}catch{}
 }
}
async function sendToPrinter(bytes:Uint8Array){
 if(nativeBle())return sendToNativePrinter(bytes);
 const device=await resolvePrinter(),characteristic=await writableCharacteristic(device),chunkSize=20;
 for(let offset=0;offset<bytes.length;offset+=chunkSize){
  const chunk=bytes.slice(offset,offset+chunkSize);
  if(characteristic.properties?.write&&characteristic.writeValue)await withTimeout(characteristic.writeValue(chunk));
  else if(characteristic.properties?.writeWithoutResponse&&characteristic.writeValueWithoutResponse)await withTimeout(characteristic.writeValueWithoutResponse(chunk));
  else throw new Error("The printer's Bluetooth write channel is no longer available. Reconnect it in Printer Settings.");
  await wait(25);
 }
 return String(device.name||"Bluetooth printer");
}

export async function printBluetoothTest(){
 return sendToPrinter(receiptBytes([`Date: ${new Date().toLocaleString()}`,"Connection: Direct Bluetooth","Format: 58 mm ESC/POS"]));
}

export async function printBluetoothReceipt(receipt:BluetoothReceipt){if(activePrint)return activePrint;activePrint=sendToPrinter(actualReceiptBytes(receipt));try{return await activePrint}finally{activePrint=null}}
