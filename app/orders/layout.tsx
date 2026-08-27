import SharedSidebar from "../SharedSidebar";

export default function OrdersLayout({children}:{children:React.ReactNode}){
 return <div className="appShell"><SharedSidebar active="orders"/>{children}</div>;
}
