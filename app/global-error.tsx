"use client";
import {useEffect} from "react";
import {reportSystemError} from "../lib/errorReporter";
export default function GlobalError({error,reset}:{error:Error&{digest?:string};reset:()=>void}){useEffect(()=>{void reportSystemError(error,{severity:"critical",code:error.digest??"RENDER_FAILURE"})},[error]);return <html><body><main className="onboarding"><section className="onboardCard"><div className="logoMark">LF</div><p className="eyebrow">SYSTEM ERROR</p><h1>Something went wrong</h1><p className="muted">The LabaFlow support team has been alerted. You can safely try loading the page again.</p><button className="primary wide" onClick={reset}>Try Again</button></section></main></body></html>}
