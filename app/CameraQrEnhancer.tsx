"use client";

import { useEffect,useRef,useState } from "react";

export default function CameraQrEnhancer(){
 const [open,setOpen]=useState(false),[error,setError]=useState(""),[status,setStatus]=useState("Point the camera at the customer's LabaFlow QR code.");
 const videoRef=useRef<HTMLVideoElement|null>(null),streamRef=useRef<MediaStream|null>(null),rafRef=useRef<number|null>(null),scanningRef=useRef(false);

 useEffect(()=>{
  const enhance=()=>{
   const bars=Array.from(document.querySelectorAll<HTMLElement>(".scanBar"));
   for(const bar of bars){
    const input=bar.querySelector<HTMLInputElement>('input[placeholder*="QR" i]');
    if(!input||bar.querySelector('[data-camera-qr-button]'))continue;
    const button=document.createElement("button");
    button.type="button";button.className="secondary cameraQrButton";button.dataset.cameraQrButton="1";button.textContent="Scan with Camera";
    button.onclick=()=>{setError("");setStatus("Point the camera at the customer's LabaFlow QR code.");setOpen(true)};
    bar.appendChild(button);
   }
  };
  enhance();const observer=new MutationObserver(enhance);observer.observe(document.body,{childList:true,subtree:true});return()=>observer.disconnect();
 },[]);

 useEffect(()=>{if(open)startCamera();else stopCamera();return()=>stopCamera()},[open]);

 function stopCamera(){scanningRef.current=false;if(rafRef.current!=null)cancelAnimationFrame(rafRef.current);rafRef.current=null;streamRef.current?.getTracks().forEach(t=>t.stop());streamRef.current=null;if(videoRef.current)videoRef.current.srcObject=null}

 async function startCamera(){
  try{
   if(!navigator.mediaDevices?.getUserMedia)throw new Error("Camera access is not supported by this browser.");
   const Detector=(window as any).BarcodeDetector;
   if(!Detector)throw new Error("QR camera scanning is not supported by this browser. Please use the latest Chrome or Edge, or use a handheld QR scanner.");
   const supported=Detector.getSupportedFormats?await Detector.getSupportedFormats():["qr_code"];
   if(!supported.includes("qr_code"))throw new Error("This browser camera does not support QR-code detection.");
   const stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:{ideal:"environment"}},audio:false});
   streamRef.current=stream;
   const video=videoRef.current;if(!video)return;video.srcObject=stream;await video.play();
   const detector=new Detector({formats:["qr_code"]});scanningRef.current=true;
   const scan=async()=>{
    if(!scanningRef.current)return;
    try{
     if(video.readyState>=2){const codes=await detector.detect(video);const raw=codes?.[0]?.rawValue?.trim();if(raw){await handleResult(raw);return}}
    }catch{}
    rafRef.current=requestAnimationFrame(scan);
   };
   scan();
  }catch(e:any){setError(e?.message||"Unable to start camera.");setStatus("")}
 }

 async function handleResult(raw:string){
  scanningRef.current=false;setStatus("QR found. Opening customer order…");
  const token=raw.replace(/^labaflow:/i,"").trim();
  const bars=Array.from(document.querySelectorAll<HTMLElement>(".scanBar"));
  const bar=bars.find(x=>x.querySelector<HTMLInputElement>('input[placeholder*="QR" i]'));
  const input=bar?.querySelector<HTMLInputElement>('input[placeholder*="QR" i]');
  const start=bar?.querySelector<HTMLButtonElement>("button.primary");
  if(!input||!start){setError("The Dashboard QR order field is not available. Return to Dashboard and try again.");return}
  const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value")?.set;setter?.call(input,token);input.dispatchEvent(new Event("input",{bubbles:true}));input.dispatchEvent(new Event("change",{bubbles:true}));
  stopCamera();setOpen(false);setTimeout(()=>start.click(),80);
 }

 return open?<div className="modalBackdrop cameraQrBackdrop" onMouseDown={()=>setOpen(false)}><section className="modal cameraQrModal" onMouseDown={e=>e.stopPropagation()}><div className="panelHead"><div><p className="eyebrow">CUSTOMER QR</p><h2>Scan with Camera</h2><span>Use the customer card or QR displayed on their phone.</span></div><button className="iconBtn" type="button" onClick={()=>setOpen(false)}>×</button></div><div className="cameraViewport"><video ref={videoRef} muted playsInline/><div className="cameraFrame"><span/><span/><span/><span/></div></div>{status&&<p className="cameraStatus">{status}</p>}{error&&<div className="notice cameraError">{error}<br/><small>Make sure camera permission is allowed for localhost in your browser settings.</small></div>}<div className="cameraQrActions"><button type="button" className="secondary" onClick={()=>setOpen(false)}>Cancel</button>{error&&<button type="button" className="primary" onClick={()=>{setError("");setStatus("Point the camera at the customer's LabaFlow QR code.");startCamera()}}>Try Again</button>}</div></section></div>:null;
}
