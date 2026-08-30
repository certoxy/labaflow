import SharedSidebar from "../SharedSidebar";

export default function SyncLayout({children}:{children:React.ReactNode}){
  return <div className="appShell"><SharedSidebar active="sync"/>{children}</div>;
}
