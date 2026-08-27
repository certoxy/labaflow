import SharedSidebar from "../SharedSidebar";

export default function CustomersLayout({children}:{children:React.ReactNode}){
 return <div className="appShell"><SharedSidebar active="customers"/>{children}</div>;
}
