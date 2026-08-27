import SharedSidebar from "../SharedSidebar";

export default function AdminLayout({children}:{children:React.ReactNode}){
 return <div className="appShell"><SharedSidebar active="platform"/>{children}</div>;
}
