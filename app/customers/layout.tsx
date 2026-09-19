import SharedSidebar from "../SharedSidebar";
import "./branch-cards.css";

export default function CustomersLayout({children}:{children:React.ReactNode}){
 return <div className="appShell"><SharedSidebar active="customers"/>{children}</div>;
}
