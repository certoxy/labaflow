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

async function sendToPrinter(bytes:Uint8Array){const device=await resolvePrinter(),characteristic=await writableCharacteristic(device);for(let offset=0;offset<bytes.length;offset+=100){const chunk=bytes.slice(offset,offset+100);if(characteristic.properties?.writeWithoutResponse&&characteristic.writeValueWithoutResponse)await characteristic.writeValueWithoutResponse(chunk);else await characteristic.writeValue(chunk)}return String(device.name||"Bluetooth printer")}

export async function printBluetoothTest(){
 return sendToPrinter(receiptBytes([`Date: ${new Date().toLocaleString()}`,"Connection: Direct Bluetooth","Format: 58 mm ESC/POS"]));
}

export async function printBluetoothReceipt(receipt:BluetoothReceipt){if(activePrint)return activePrint;activePrint=sendToPrinter(actualReceiptBytes(receipt));try{return await activePrint}finally{activePrint=null}}
