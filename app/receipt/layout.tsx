import SharedSidebar from "../SharedSidebar";
import ReceiptProducts from "./ReceiptProducts";

export default function ReceiptLayout({children}:{children:React.ReactNode}){
 return <div className="appShell"><SharedSidebar active="orders"/>{children}<ReceiptProducts/></div>;
}
