import SharedSidebar from "../SharedSidebar";
export default function DashboardLayout({children}:{children:React.ReactNode}){return <div className="appShell"><SharedSidebar active="dashboard"/>{children}</div>}
